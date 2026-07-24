//
//  TerminalRouting.swift
//  HerdBridge
//
//  Routes a clicked agent to the EXACT terminal window hosting its herdr
//  client — not just the app:
//    reef/session → herdr client PID (process table; remote clients are
//    `herdr --remote <target>`) → kitty window whose foreground_processes
//    contain that PID (kitty remote control `ls`) → focus-window --match id:N
//  Falls back to plain app activation, and can launch a fresh attached window
//  when no client exists. kitty first; other terminals degrade to activation.
//  This is the reusable click→window engine — no SwiftUI, no notch — so it
//  lives in the library alongside the session logic it serves.
//
//  kitty requires in kitty.conf (full restart needed):
//    allow_remote_control socket-only
//    listen_on unix:/tmp/kitty-{kitty_pid}
//

import Foundation
import AppKit

public enum RouteOutcome {
    case focusedWindow            // precise window focused
    case activatedOnly(String?)   // app-level activation; optional hint why
    case launched                 // opened a new attached window
}

public enum TerminalRouter {

    /// Rate limit: a click must never machine-gun new terminal windows. A
    /// best-effort guard — a benign race here at worst allows one extra
    /// window, so unsynchronized access is acceptable.
    nonisolated(unsafe) private static var lastLaunch = Date.distantPast

    /// Bring a terminal app to the front (launch if not running). This is the
    /// instant-feedback step of a click; precise window routing follows.
    @MainActor
    public static func activate(bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Blocking (ps + kitten calls) — call from a background task.
    /// LS-FIRST strategy: enumerate the windows that actually run a herdr
    /// client for this reef from kitty's own listing; the ps-resolved client
    /// pid only REFINES the choice. Launching happens only when kitty shows
    /// no herdr window at all for the reef — never on a fuzzy ps miss.
    public static func route(reef: ReefConfig) -> RouteOutcome {
        log("route reef=\(reef.label) ssh=\(reef.isSSH)")
        guard reef.terminalBundleID == TerminalApp.kitty.bundleID else {
            return .activatedOnly(nil)   // precise routing implemented for kitty first
        }
        let sockets = kittySockets()
        if sockets.isEmpty {
            return .activatedOnly("kitty remote control is off — add “allow_remote_control socket-only” and “listen_on unix:/tmp/kitty-{kitty_pid}” to kitty.conf, then fully restart kitty")
        }
        // all windows running a herdr client that fits this reef
        var herdrWindows: [(sock: String, win: KittyWindow)] = []
        for sock in sockets {
            for w in kittyWindows(socket: sock) ?? [] {
                let matches = w.cmdlines.contains { cmd in
                    let isHerdr = cmd == "herdr" || cmd.hasPrefix("herdr ") || cmd.contains("/herdr")
                    guard isHerdr, !cmd.contains(" server") else { return false }
                    return reef.isSSH
                        ? (cmd.contains("--remote") && cmd.contains(reef.sshTarget ?? ""))
                        : !cmd.contains("--remote")
                }
                if matches { herdrWindows.append((sock, w)) }
            }
        }
        log("herdr windows: \(herdrWindows.map { "\($0.win.id)@\($0.sock)" }.joined(separator: ","))")
        // the ps scan (~100ms) only pays off when several windows qualify
        var best = herdrWindows.first
        if herdrWindows.count > 1 {
            let table = processTable()
            let client = findHerdrClient(for: reef, in: table)
            log("refining among \(herdrWindows.count) via ps client=\(client.map { String($0.pid) } ?? "none")")
            let ancestry = client.map { Set(ancestryChain(of: $0.pid, in: table)) } ?? []
            best = herdrWindows.first { c in client.map { c.win.fgPIDs.contains($0.pid) } ?? false }
                ?? herdrWindows.first { !$0.win.fgPIDs.isDisjoint(with: ancestry) }
                ?? herdrWindows.first
        }
        if let best {
            log("focusing window id=\(best.win.id)")
            if kitten(["@", "--to", "unix:\(best.sock)", "focus-window", "--match", "id:\(best.win.id)"]) != nil {
                return .focusedWindow
            }
            return .activatedOnly("focus-window failed for id \(best.win.id)")
        }
        // kitty shows NO herdr window for this reef → open one, rate-limited
        guard Date().timeIntervalSince(lastLaunch) > 5 else {
            return .activatedOnly("no herdr window for this reef (launch suppressed — just launched)")
        }
        lastLaunch = Date()
        log("no herdr window; launching attached client")
        return launchAttached(reef: reef) ? .launched
            : .activatedOnly("no herdr window for this reef and launch failed")
    }

    private static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: "/tmp/herd-routing.log") {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/herd-routing.log", contents: Data(line.utf8))
        }
    }

    // MARK: herdr client resolution (terminal-agnostic)

    private struct Proc { let pid: pid_t; let ppid: pid_t; let tty: String; let cmd: String }
    private struct Client { let pid: pid_t }

    private static func processTable() -> [pid_t: Proc] {
        guard let out = run("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="]) else { return [:] }
        var table: [pid_t: Proc] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            let cmd = parts[3...].joined(separator: " ")
            table[pid] = Proc(pid: pid, ppid: ppid, tty: String(parts[2]), cmd: cmd)
        }
        return table
    }

    private static func findHerdrClient(for reef: ReefConfig, in table: [pid_t: Proc]) -> Client? {
        // deterministic order (dictionary values are not!)
        let candidates = table.values
            .filter { p in
                p.tty != "??" && (p.cmd == "herdr" || p.cmd.hasSuffix("/herdr") || p.cmd.contains("herdr "))
                    && !p.cmd.contains(" server") && !p.cmd.contains(" api ")
            }
            .sorted { $0.pid < $1.pid }
        if reef.isSSH {
            let target = reef.sshTarget ?? ""
            return candidates.first { $0.cmd.contains("--remote") && $0.cmd.contains(target) }.map { Client(pid: $0.pid) }
        }
        // local: prefer plain attach (no --remote); named sessions match --session
        return candidates.first { !$0.cmd.contains("--remote") }.map { Client(pid: $0.pid) }
    }

    private static func ancestryChain(of pid: pid_t, in table: [pid_t: Proc]) -> [pid_t] {
        var chain: [pid_t] = [], cur = pid
        while let p = table[cur], p.ppid > 1, chain.count < 12 {
            chain.append(p.ppid)
            cur = p.ppid
        }
        return chain
    }

    // MARK: kitty remote control

    private static let kittenPath = "/Applications/kitty.app/Contents/MacOS/kitten"

    private static func kittySockets() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [])
            .filter { $0.hasPrefix("kitty-") && !$0.hasSuffix(".log") }
            .map { "/tmp/\($0)" }
            // stale sockets from previous kitty instances linger in /tmp and
            // make kitten hang — only talk to ones that actually accept
            .filter { HerdSessionDiscovery.probe($0) }
    }

    private struct KittyWindow { let id: Int; let fgPIDs: Set<pid_t>; let cmdlines: [String] }

    private static func kittyWindows(socket: String) -> [KittyWindow]? {
        guard let out = run(kittenPath, ["@", "--to", "unix:\(socket)", "ls"]),
              let data = out.data(using: .utf8),
              let osWindows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var result: [KittyWindow] = []
        for os in osWindows {
            for tab in os["tabs"] as? [[String: Any]] ?? [] {
                for w in tab["windows"] as? [[String: Any]] ?? [] {
                    guard let id = w["id"] as? Int else { continue }
                    var pids = Set<pid_t>(), cmds: [String] = []
                    for p in w["foreground_processes"] as? [[String: Any]] ?? [] {
                        if let pid = p["pid"] as? Int { pids.insert(pid_t(pid)) }
                        if let cl = p["cmdline"] as? [String] { cmds.append(cl.joined(separator: " ")) }
                    }
                    result.append(KittyWindow(id: id, fgPIDs: pids, cmdlines: cmds))
                }
            }
        }
        return result
    }

    // MARK: launch

    private static func herdrBinary(in table: [pid_t: Proc]) -> String {
        if let server = table.values.first(where: { $0.cmd.hasSuffix("herdr server") }) {
            return String(server.cmd.dropLast(" server".count))
        }
        return "\(NSHomeDirectory())/.local/bin/herdr"
    }

    private static func launchAttached(reef: ReefConfig) -> Bool {
        let table = processTable()
        let herdr = herdrBinary(in: table)
        var cmd = [herdr]
        if reef.isSSH, let target = reef.sshTarget { cmd += ["--remote", target] }
        // prefer a window inside the running instance; else a fresh kitty
        for sock in kittySockets() {
            if kitten(["@", "--to", "unix:\(sock)", "launch", "--type=os-window", "--title", "herdr"] + cmd) != nil {
                return true
            }
        }
        return run("/usr/bin/open", ["-na", "kitty", "--args", "--title", "herdr"] + cmd) != nil
    }

    // MARK: process helpers

    @discardableResult
    private static func kitten(_ args: [String]) -> String? { run(kittenPath, args) }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // watchdog: never let a hung subprocess block routing
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
        // read BEFORE waitUntilExit: output larger than the 64KB pipe buffer
        // (ps -axo command easily is) deadlocks the child otherwise — the
        // watchdog then kills it after `timeout`, stalling every route call.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
