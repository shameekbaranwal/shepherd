import Foundation

/// Agent status as emitted by herdr (protocol v16).
public enum AgentStatus: String, Decodable, Sendable, CaseIterable {
    case idle, working, blocked, done, unknown
}

// MARK: - session.snapshot

struct SnapshotResult: Decodable, Sendable {
    let snapshot: SessionSnapshot
}

public struct SessionSnapshot: Decodable, Sendable {
    public let agents: [AgentInfo]
    public let workspaces: [WorkspaceInfo]
    public let tabs: [TabInfo]
}

public struct AgentInfo: Decodable, Sendable {
    public let agent: String?
    public let agentStatus: AgentStatus
    public let paneID: String
    public let tabID: String
    public let workspaceID: String
    public let cwd: String?
    public let focused: Bool?

    enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus = "agent_status"
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case cwd, focused
    }
}

public struct WorkspaceInfo: Decodable, Sendable {
    public let workspaceID: String
    public let label: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
    }
}

public struct TabInfo: Decodable, Sendable {
    public let tabID: String
    public let label: String?
    public let workspaceID: String

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case label
        case workspaceID = "workspace_id"
    }
}

// MARK: - events

/// Wire envelope for pushed events: {"event": "...", "data": {...}}
struct EventEnvelope<T: Decodable>: Decodable {
    let event: String
    let data: T
}

public struct PaneAgentStatusChangedEvent: Decodable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let agentStatus: AgentStatus
    public let agent: String?
    public let customStatus: String?
    public let title: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agentStatus = "agent_status"
        case agent
        case customStatus = "custom_status"
        case title
    }
}

struct SubscriptionAck: Decodable, Sendable {
    let type: String
}

/// `pane_agent_detected` payload. Fires periodically for every pane as
/// re-detection noise; only meaningful when it introduces a new agent pane
/// or reports a release.
struct PaneAgentDetectedEvent: Decodable, Sendable {
    let paneID: String
    let agent: String?
    let released: Bool?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case agent, released
    }
}
