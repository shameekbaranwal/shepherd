import Foundation

// Phase-0 stubs for the extensibility spine. These interfaces are part of the
// core design (adapters + segment statusline); implementations land later.

/// What kind of input a blocked agent is waiting for.
public enum PromptKind: String, Sendable {
    case permission
    case planApprove
    case multipleChoice
    case freeText
}

/// Typed, runtime-agnostic facts about one agent, produced by an AgentAdapter.
/// Everything beyond `state` is best-effort and adapter-dependent.
public struct AgentFacts: Sendable {
    public var state: AgentStatus
    public var model: String?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUSD: Double?
    public var currentTool: String?
    public var promptKind: PromptKind?
    public var lastLine: String?

    public init(state: AgentStatus) {
        self.state = state
    }
}

/// One adapter per agent runtime (claude, codex, cursor, custom …).
/// Sources: herdr status/explain, registered output watchers, sidecar files,
/// shelled commands. Adapters enrich; they never override herdr's pane model.
public protocol AgentAdapter: Sendable {
    /// Runtime label this adapter handles (matches herdr's `agent` field).
    var runtime: String { get }
    func facts(for agent: HerdAgent) async -> AgentFacts
}

/// Fallback adapter: herdr's status, nothing else.
public struct DefaultAdapter: AgentAdapter {
    public let runtime = "*"
    public init() {}
    public func facts(for agent: HerdAgent) async -> AgentFacts {
        AgentFacts(state: agent.status)
    }
}

/// A rendered statusline chip.
public struct SegmentChip: Sendable {
    public var icon: String
    public var text: String
    /// Semantic color name; the UI maps it to theme colors.
    public var color: String

    public init(icon: String, text: String, color: String = "default") {
        self.icon = icon
        self.text = text
        self.color = color
    }
}

/// A statusline segment: pure function from facts to an optional chip.
/// (Starship/tmux-powerline model; `command=` shell segments come later.)
public protocol Segment: Sendable {
    var id: String { get }
    func render(_ facts: AgentFacts) -> SegmentChip?
}
