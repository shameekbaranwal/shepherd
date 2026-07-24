import Foundation

/// Aggregates several herdr sessions (local named sessions, remote proxy
/// sockets) into one merged herd. Each session becomes a "reef": its label
/// is stamped on HerdAgent.machine and pane ids are session-qualified.
public actor HerdMultiBridge {
    public struct Session: Sendable, Identifiable, Hashable {
        public var id: String { label }
        public let label: String
        public let socketPath: String
        public init(label: String, socketPath: String) {
            self.label = label
            self.socketPath = socketPath
        }
    }

    private var bridges: [String: HerdBridge] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var agents: [String: HerdAgent] = [:]   // keyed by HerdAgent.id
    private var out: AsyncStream<HerdUpdate>.Continuation?
    private var statusByLabel: [String: String] = [:]

    /// Human-readable per-session connection status (for settings UIs).
    public func statuses() -> [String: String] { statusByLabel }

    public init() {}

    /// Start (or restart) with the given sessions. Returns the merged stream.
    public func run(sessions: [Session]) -> AsyncStream<HerdUpdate> {
        let (stream, cont) = AsyncStream<HerdUpdate>.makeStream()
        out = cont
        setSessions(sessions)
        return stream
    }

    /// Reconcile the running session set (add new, drop removed).
    public func setSessions(_ sessions: [Session]) {
        let want = Dictionary(uniqueKeysWithValues: sessions.map { ($0.label, $0) })
        // drop removed
        for label in bridges.keys where want[label] == nil {
            tasks[label]?.cancel()
            tasks[label] = nil
            let bridge = bridges[label]
            Task { await bridge?.shutdown() }
            bridges[label] = nil
            agents = agents.filter { $0.value.machine != label }
            statusByLabel[label] = nil
        }
        // add new
        for (label, session) in want where bridges[label] == nil {
            let bridge = HerdBridge(socketPath: session.socketPath, label: label)
            bridges[label] = bridge
            tasks[label] = Task { [weak self] in
                await self?.consume(bridge: bridge, label: label)
            }
        }
        emitHydrated()
    }

    /// Per-session consume loop with reconnect backoff — a dead session
    /// (remote proxy gone) empties its reef and keeps retrying quietly.
    private func consume(bridge: HerdBridge, label: String) async {
        while !Task.isCancelled {
            statusByLabel[label] = "connecting…"
            do {
                let stream = try await bridge.run()
                for await update in stream {
                    apply(update, label: label)
                }
                statusByLabel[label] = "stream ended — retrying"
            } catch {
                statusByLabel[label] = "error: \((error as? HerdrError)?.description ?? String(describing: error))"
            }
            agents = agents.filter { $0.value.machine != label }
            emitHydrated()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func apply(_ update: HerdUpdate, label: String) {
        switch update {
        case .hydrated(let list):
            agents = agents.filter { $0.value.machine != label }
            for a in list { agents[a.id] = a }
            statusByLabel[label] = "connected · \(list.count) agent\(list.count == 1 ? "" : "s")"
            emitHydrated()
        case .transition(let agent, let from):
            agents[agent.id] = agent
            out?.yield(.transition(agent: agent, from: from))
        }
    }

    private func emitHydrated() {
        out?.yield(.hydrated(agents.values.sorted(by: HerdBridge.attentionSort)))
    }

    // MARK: actions — routed to the owning session's bridge

    public func focus(agent: HerdAgent) async {
        await bridges[agent.machine]?.focus(paneID: agent.paneID)
    }

    public func ack(agent: HerdAgent) async {
        await bridges[agent.machine]?.ack(paneID: agent.paneID)
    }

    public func shutdown() async {
        for (_, t) in tasks { t.cancel() }
        for (_, b) in bridges { await b.shutdown() }
        tasks.removeAll(); bridges.removeAll()
        out?.finish()
    }
}

// MARK: - discovery

public enum HerdSessionDiscovery {
    public struct Found: Sendable, Identifiable {
        public var id: String { socketPath }
        public let suggestedLabel: String
        public let socketPath: String
        public let alive: Bool
    }

    /// Known socket locations: the default session, named local sessions,
    /// and remote attach proxies (herdr-remote-<pid>-<target>-<session>.sock).
    public static func discover() -> [Found] {
        var found: [Found] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let def = "\(home)/.config/herdr/herdr.sock"
        if fm.fileExists(atPath: def) {
            found.append(Found(suggestedLabel: "local", socketPath: def, alive: probe(def)))
        }
        let sessionsDir = "\(home)/.config/herdr/sessions"
        for name in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] {
            let sock = "\(sessionsDir)/\(name)/herdr.sock"
            if fm.fileExists(atPath: sock) {
                found.append(Found(suggestedLabel: name, socketPath: sock, alive: probe(sock)))
            }
        }
        // NOTE: herdr's --remote attach proxies ($TMPDIR/herdr-remote-*.sock)
        // are deliberately NOT offered: verified empirically that they accept
        // connections but never answer API requests (attach transport, not an
        // API proxy). Remote herds need an SSH unix-socket forward to the
        // remote server's real socket instead.
        return found
    }

    /// Cheap liveness probe: can we connect to the unix socket at all?
    public static func probe(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok: Bool = path.withCString { cs in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                guard path.utf8.count < raw.count else { return false }
                raw.baseAddress!.assumingMemoryBound(to: CChar.self).update(from: cs, count: path.utf8.count + 1)
                return true
            }
        }
        guard ok else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, len)
            }
        }
        return res == 0
    }
}
