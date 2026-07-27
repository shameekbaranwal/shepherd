import Foundation

/// One agent pane, as the UI sees it.
public struct HerdAgent: Sendable, Identifiable {
    /// Session-qualified: pane ids repeat across herdr sessions.
    public var id: String { "\(machine)/\(paneID)" }
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public var workspaceLabel: String
    public var tabLabel: String
    public var agent: String
    /// Which machine this agent runs on ("local" for the default socket;
    /// remote herds get their host label when multi-socket lands).
    public var machine: String
    public var status: AgentStatus
    public var cwd: String
    /// When the current status began (best effort; snapshot rows keep prior value).
    public var since: Date
    /// Completion latch. herdr's `done` is EPHEMERAL (focusing the pane
    /// collapses it to `idle`), and for heuristic agents like Claude Code the
    /// practical completion signal is the `working → idle` edge. So the bridge
    /// latches completion as its own derived fact: set on `working → idle/done`
    /// (and `blocked → done`), survives herdr's done→idle collapse, cleared
    /// when the agent starts working again or via `ack(paneID:)`.
    public var finishedAt: Date?

    /// Finished and not yet acknowledged — what the attention queue keys on.
    public var needsAck: Bool { finishedAt != nil }
}

public enum HerdUpdate: Sendable {
    /// Full state (initial hydration and after any lifecycle change).
    case hydrated([HerdAgent])
    /// A single agent changed status.
    case transition(agent: HerdAgent, from: AgentStatus)
}

/// Live model of the herd: hydrates from `session.snapshot`, then follows the
/// push event stream. Lifecycle events (pane/tab/workspace created/closed/…)
/// trigger a debounced re-hydration + resubscribe, since per-pane status
/// subscriptions must track the current set of agent panes.
public actor HerdBridge {
    private let socketPath: String
    /// Reef/session label stamped onto every agent (HerdAgent.machine).
    private let label: String
    private var eventConn: HerdrConnection?
    private var eventTask: Task<Void, Never>?
    private var rehydrateTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private var agents: [String: HerdAgent] = [:]
    private var subscribedPanes: Set<String> = []
    private var out: AsyncStream<HerdUpdate>.Continuation?

    /// How often the safety reconcile polls the snapshot as an event backstop.
    private static let safetyInterval: UInt64 = 20_000_000_000   // 20s

    /// Events that mean "the shape of the herd may have changed".
    /// (`pane_agent_detected` is handled separately — it fires as periodic
    /// re-detection noise for every pane.)
    private static let lifecycleEvents: Set<String> = [
        "pane_created", "pane_closed", "pane_exited", "pane_moved",
        "tab_created", "tab_closed", "tab_renamed",
        "workspace_created", "workspace_closed", "workspace_renamed",
    ]

    public init(socketPath: String, label: String = "local") {
        self.socketPath = socketPath
        self.label = label
    }

    /// Connect, hydrate, subscribe. Returns the update stream.
    public func run() async throws -> AsyncStream<HerdUpdate> {
        let (stream, cont) = AsyncStream<HerdUpdate>.makeStream()
        out = cont
        try await rehydrate()
        startSafetyLoop()
        return stream
    }

    public func shutdown() async {
        eventTask?.cancel()
        rehydrateTask?.cancel()
        safetyTask?.cancel()
        await eventConn?.close()
        out?.finish()
    }

    /// Event backstop: even with the lifecycle subscriptions, a herd can drift
    /// if herdr never emits (or we miss) a create/status event — the agent then
    /// stays invisible until the next manual reconnect. This loop periodically
    /// re-snapshots and, ONLY when the pane set or a status actually diverges
    /// from what we hold, schedules a (debounced, coalescing) rehydrate. A
    /// clean herd costs one cheap snapshot read per interval and yields nothing.
    private func startSafetyLoop() {
        safetyTask?.cancel()
        safetyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.safetyInterval)
                if Task.isCancelled { return }
                await self?.reconcile()
            }
        }
    }

    private func reconcile() async {
        guard let snap = try? await oneShot("session.snapshot", as: SnapshotResult.self).snapshot else { return }
        let snapPanes = Set(snap.agents.map(\.paneID))
        let curPanes = Set(agents.keys)
        // topology drift (pane added/removed), or a status a missed event left stale
        let statusDrift = snap.agents.contains { agents[$0.paneID]?.status != $0.agentStatus }
        if snapPanes != curPanes || statusDrift {
            debugLog("safety reconcile: drift detected (panes \(curPanes.count)→\(snapPanes.count)), rehydrating")
            scheduleRehydrate()
        }
    }

    /// herdr connections are one-shot: fresh connection per request.
    private func oneShot<T: Decodable & Sendable>(_ method: String, params: JSON = .object([:]), as type: T.Type) async throws -> T {
        let conn = HerdrConnection(socketPath: socketPath)
        try await conn.connect()
        defer { Task { await conn.close() } }
        return try await conn.request(method, params: params, as: type)
    }

    // MARK: - hydration + subscription

    private func rehydrate() async throws {
        let snap = try await oneShot("session.snapshot", as: SnapshotResult.self).snapshot

        let wsLabels = Dictionary(uniqueKeysWithValues: snap.workspaces.map { ($0.workspaceID, $0.label ?? $0.workspaceID) })
        let tabLabels = Dictionary(uniqueKeysWithValues: snap.tabs.map { ($0.tabID, $0.label ?? $0.tabID) })

        var next: [String: HerdAgent] = [:]
        for info in snap.agents {
            let previous = agents[info.paneID]
            let since = (previous?.status == info.agentStatus) ? (previous?.since ?? Date()) : Date()
            // Snapshot is TOPOLOGY truth (which agents exist, labels, cwd).
            // The completion latch is ours: carry it across rehydrates, and if
            // the working→idle/done edge happened while we weren't looking
            // (connection swap), latch it here too.
            var finishedAt = previous?.finishedAt
            if let previous, previous.status == .working,
               info.agentStatus == .idle || info.agentStatus == .done {
                finishedAt = Date()
            }
            if info.agentStatus == .working { finishedAt = nil }
            next[info.paneID] = HerdAgent(
                paneID: info.paneID,
                workspaceID: info.workspaceID,
                tabID: info.tabID,
                workspaceLabel: wsLabels[info.workspaceID] ?? info.workspaceID,
                tabLabel: tabLabels[info.tabID] ?? info.tabID,
                agent: info.agent ?? "agent",
                machine: label,
                status: info.agentStatus,
                cwd: info.cwd ?? "",
                since: since,
                finishedAt: finishedAt
            )
        }
        agents = next
        out?.yield(.hydrated(sortedAgents()))

        let panes = Set(next.keys)
        if panes != subscribedPanes || eventConn == nil {
            try await resubscribe(panes: panes)
        }
    }

    private func resubscribe(panes: Set<String>) async throws {
        // Subscription types use a dot at the first separator only
        // (e.g. "pane.agent_status_changed"); pushed events use underscores.
        var subs: [JSON] = [
            ["type": "pane.created"], ["type": "pane.closed"], ["type": "pane.exited"],
            ["type": "pane.agent_detected"], ["type": "pane.moved"],
            ["type": "tab.created"], ["type": "tab.closed"], ["type": "tab.renamed"],
            ["type": "workspace.created"], ["type": "workspace.closed"], ["type": "workspace.renamed"],
        ]
        for pane in panes.sorted() {
            subs.append(["type": "pane.agent_status_changed", "pane_id": .string(pane)])
        }

        let fresh = HerdrConnection(socketPath: socketPath)
        try await fresh.connect()
        let stream = try await fresh.subscribe(subs)

        eventTask?.cancel()
        await eventConn?.close()
        eventConn = fresh
        subscribedPanes = panes
        eventTask = Task { [weak self] in
            for await (event, data) in stream {
                await self?.handle(event: event, data: data)
            }
            // Stream ended (server closed / connection lost): try to recover.
            await self?.scheduleRehydrate()
        }
    }

    // MARK: - event handling

    private func debugLog(_ msg: String) {
        if ProcessInfo.processInfo.environment["HERD_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[bridge] \(msg)\n".utf8))
        }
    }

    private func handle(event: String, data: Data) {
        debugLog("handle \(event)")
        switch event {
        // NOTE: unlike lifecycle events (underscores), this one is pushed
        // with a DOT in the name — verified on the wire against herdr 0.7.x.
        case "pane.agent_status_changed", "pane_agent_status_changed":
            guard let env = try? JSONDecoder().decode(EventEnvelope<PaneAgentStatusChangedEvent>.self, from: data) else { return }
            apply(env.data)
        case "pane_agent_detected":
            guard let env = try? JSONDecoder().decode(EventEnvelope<PaneAgentDetectedEvent>.self, from: data) else { return }
            let d = env.data
            // Rehydrate only when this changes the herd's shape: an agent on a
            // pane we don't track yet, or an agent released from a pane we do.
            if d.released == true && agents[d.paneID] != nil {
                scheduleRehydrate()
            } else if d.agent != nil && agents[d.paneID] == nil {
                scheduleRehydrate()
            }
        default:
            if Self.lifecycleEvents.contains(event) {
                scheduleRehydrate()
            }
        }
    }

    private func apply(_ e: PaneAgentStatusChangedEvent) {
        guard var a = agents[e.paneID] else {
            scheduleRehydrate()
            return
        }
        guard a.status != e.agentStatus else { return }
        let old = a.status
        a.status = e.agentStatus
        a.since = Date()
        if let name = e.agent { a.agent = name }
        // Completion latch (see HerdAgent.finishedAt). Idempotent under the
        // server's event replay: re-applying the same edge is a no-op above.
        switch (old, e.agentStatus) {
        case (.working, .idle), (.working, .done), (.blocked, .done):
            a.finishedAt = Date()
        case (_, .working):
            a.finishedAt = nil
        default:
            break
        }
        agents[e.paneID] = a
        out?.yield(.transition(agent: a, from: old))
    }

    /// Focus an agent's pane in the terminal (workspace/tab/pane jump).
    public func focus(paneID: String) async {
        struct AnyResult: Decodable, Sendable { let type: String? }
        _ = try? await oneShot("agent.focus", params: ["target": .string(paneID)], as: AnyResult.self)
    }

    /// Acknowledge a finished agent: clears the completion latch.
    public func ack(paneID: String) {
        guard var a = agents[paneID], a.finishedAt != nil else { return }
        a.finishedAt = nil
        agents[paneID] = a
        out?.yield(.hydrated(sortedAgents()))
    }

    /// Coalescing, leading-edge debounce: lifecycle events arrive in bursts
    /// (splits, workspace churn, and the server's event REPLAY on subscribe).
    /// A trailing-edge debounce starves under continuous noise — instead,
    /// later triggers coalesce into the already-scheduled rehydrate.
    /// Note: replay → rehydrate cannot loop, because resubscribe (and hence a
    /// fresh replay) only happens when the agent-pane set actually changed.
    private func scheduleRehydrate() {
        guard rehydrateTask == nil else { return }
        rehydrateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self?.runScheduledRehydrate()
        }
    }

    private func runScheduledRehydrate() async {
        rehydrateTask = nil
        do {
            try await rehydrate()
        } catch {
            debugLog("rehydrate FAILED: \(error)")
        }
    }

    /// Attention rank: blocked → finished-unacked → working → idle → unknown.
    public static func attentionRank(_ a: HerdAgent) -> Int {
        if a.status == .blocked { return 0 }
        if a.needsAck || a.status == .done { return 1 }
        switch a.status {
        case .working: return 2
        case .idle: return 3
        default: return 4
        }
    }

    /// Attention rank, then recency — the agent that changed state last
    /// (finished/started most recently) floats to the top of its group.
    public static func attentionSort(_ a: HerdAgent, _ b: HerdAgent) -> Bool {
        let l = attentionRank(a), r = attentionRank(b)
        if l != r { return l < r }
        let la = a.finishedAt ?? a.since, rb = b.finishedAt ?? b.since
        if la != rb { return la > rb }
        return a.id < b.id
    }

    private func sortedAgents() -> [HerdAgent] {
        agents.values.sorted(by: Self.attentionSort)
    }
}
