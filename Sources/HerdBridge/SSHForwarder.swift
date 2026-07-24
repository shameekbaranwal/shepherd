//
//  SSHForwarder.swift
//  HerdBridge
//
//  Remote reefs run over an app-managed `ssh -N -L <local>:<remote> <host>`
//  unix-socket forward to the remote herdr server's REAL API socket (its own
//  --remote attach proxies don't answer API requests). This owns those
//  forwards. Pure process/session logic — no UI — so it lives in the library.
//

import Foundation

@MainActor
public final class SSHForwarder {
    public static let shared = SSHForwarder()
    private var procs: [UUID: Process] = [:]

    private init() {}

    private func localPath(for reef: ReefConfig) -> String {
        // unix socket paths are length-limited; keep it short
        "/tmp/herd-fwd-\(reef.id.uuidString.prefix(8)).sock"
    }

    public func logPath(for reef: ReefConfig) -> String {
        "/tmp/herd-fwd-\(reef.id.uuidString.prefix(8)).log"
    }

    public func isRunning(_ reef: ReefConfig) -> Bool {
        procs[reef.id]?.isRunning ?? false
    }

    /// Ensure a forward is running; returns the local socket path.
    @discardableResult
    public func ensure(_ reef: ReefConfig) -> String {
        let local = localPath(for: reef)
        if let p = procs[reef.id], p.isRunning { return local }
        try? FileManager.default.removeItem(atPath: local)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "ServerAliveInterval=15",
            "-L", "\(local):\(reef.sshRemotePath ?? "/home/\(NSUserName())/.config/herdr/herdr.sock")",
            reef.sshTarget ?? "",
        ]
        p.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: logPath(for: reef), contents: nil)
        p.standardError = FileHandle(forWritingAtPath: logPath(for: reef)) ?? FileHandle.nullDevice
        try? p.run()
        procs[reef.id] = p
        return local
    }

    /// Kill forwards for reefs that are gone or hidden.
    public func retain(only ids: Set<UUID>) {
        for (id, p) in procs where !ids.contains(id) {
            p.terminate()
            procs[id] = nil
        }
    }
}

public extension HerdSessionDiscovery {
    /// Best-guess remote herdr socket path: resolve the target's ssh user via
    /// `ssh -G` (local config resolution, no network round-trip).
    static func remoteHerdrSock(for target: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G", target]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var user = NSUserName()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("user ") }) {
                user = String(line.dropFirst(5))
            }
        }
        return "/home/\(user)/.config/herdr/herdr.sock"
    }
}
