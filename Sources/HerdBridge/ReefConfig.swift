//
//  ReefConfig.swift
//  HerdBridge
//
//  The session/reef domain model and its persistence, plus the terminal-app
//  registry. This is agent/session configuration — not presentation — so it
//  lives in the portable library, shared by every frontend (the notch fork,
//  the `herd` CLI, the `herd-notch` prototype). Presentation-only state
//  (zone weights, blade order, aliases, chosen face) stays in the frontend.
//

import Foundation

/// One reef = one herdr session. Local reefs point at a socket path. Remote
/// reefs (sshTarget set) get an app-managed `ssh -N -L` unix-socket forward to
/// the remote server's REAL API socket — herdr's own --remote attach proxies
/// do not answer API requests (verified), so the forward is the way.
public struct ReefConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var label: String
    public var socketPath: String
    public var visible: Bool
    /// Terminal app to bring forward on focus (bundle id).
    public var terminalBundleID: String
    /// SSH host (as in ~/.ssh/config) for remote reefs; nil = local socket.
    public var sshTarget: String?
    /// Absolute path of herdr.sock ON the remote machine.
    public var sshRemotePath: String?

    public init(id: UUID = UUID(), label: String, socketPath: String, visible: Bool = true,
                terminalBundleID: String = TerminalApp.kitty.bundleID,
                sshTarget: String? = nil, sshRemotePath: String? = nil) {
        self.id = id
        self.label = label
        self.socketPath = socketPath
        self.visible = visible
        self.terminalBundleID = terminalBundleID
        self.sshTarget = sshTarget
        self.sshRemotePath = sshRemotePath
    }

    public var isSSH: Bool { !(sshTarget ?? "").isEmpty }
}

/// The terminals we know how to bring forward (and, for kitty, route into a
/// precise window). Adding one here is the first step of a terminal adapter.
public enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case kitty, iterm2, ghostty, terminal, wezterm, alacritty
    public var id: String { rawValue }
    public var bundleID: String {
        switch self {
        case .kitty: return "net.kovidgoyal.kitty"
        case .iterm2: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .terminal: return "com.apple.Terminal"
        case .wezterm: return "com.github.wez.wezterm"
        case .alacritty: return "org.alacritty"
        }
    }
    public var display: String {
        switch self {
        case .kitty: return "kitty"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .terminal: return "Terminal"
        case .wezterm: return "WezTerm"
        case .alacritty: return "Alacritty"
        }
    }
}

/// Persistence for the reef registry (JSON in UserDefaults).
public enum ReefStore {
    public static let key = "herdReefConfigs"

    public static func load() -> [ReefConfig] {
        if let data = UserDefaults.standard.data(forKey: key),
           let reefs = try? JSONDecoder().decode([ReefConfig].self, from: data), !reefs.isEmpty {
            return reefs
        }
        let sock = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? "\(NSHomeDirectory())/.config/herdr/herdr.sock"
        return [ReefConfig(label: Host.current().localizedName ?? "local", socketPath: sock)]
    }

    public static func save(_ reefs: [ReefConfig]) {
        if let data = try? JSONEncoder().encode(reefs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
