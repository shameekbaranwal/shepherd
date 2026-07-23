import Foundation
import HerdBridge

// herd — phase-0 spike: a live terminal table of every herdr agent,
// updating in real time from the herdr socket's push event stream.

let socketPath = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
    ?? "\(NSHomeDirectory())/.config/herdr/herdr.sock"

// MARK: - rendering

enum ANSI {
    static let clear = "\u{1B}[2J\u{1B}[H"
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"

    static func color(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "\u{1B}[33m" // amber
        case .blocked: return "\u{1B}[31m" // red
        case .done: return "\u{1B}[32m"    // green
        case .idle: return dim
        case .unknown: return "\u{1B}[90m" // grey
        }
    }

    static func glyph(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "●"
        case .blocked: return "■"
        case .done: return "✔"
        case .idle: return "○"
        case .unknown: return "?"
        }
    }
}

func elapsed(since date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(s % 60)s" }
    return "\(s / 3600)h\((s % 3600) / 60)m"
}

func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width - 1)) + "…" }
    return s + String(repeating: " ", count: width - s.count)
}

func weather(_ agents: [HerdAgent]) -> String {
    if agents.contains(where: { $0.status == .blocked }) { return "⛈" }
    if agents.contains(where: { $0.status == .working }) { return "⛅" }
    return "☀"
}

func draw(agents: [HerdAgent], transitions: [String]) {
    var out = ANSI.clear
    let counts = Dictionary(grouping: agents, by: \.status).mapValues(\.count)
    let summary = AgentStatus.allCases
        .compactMap { st -> String? in
            guard let n = counts[st], n > 0 else { return nil }
            return "\(ANSI.color(st))\(n) \(st.rawValue)\(ANSI.reset)"
        }
        .joined(separator: " · ")
    out += "\(ANSI.bold) \(weather(agents))  herd\(ANSI.reset)  \(summary)\n\n"
    out += "\(ANSI.bold) \(pad("st", 3))\(pad("workspace", 22))\(pad("tab", 22))\(pad("agent", 8))\(pad("status", 9))\(pad("for", 8))cwd\(ANSI.reset)\n"
    for a in agents {
        let c = ANSI.color(a.status)
        let cwdTail = a.cwd.split(separator: "/").suffix(2).joined(separator: "/")
        out += " \(c)\(pad(ANSI.glyph(a.status), 3))\(ANSI.reset)"
        out += "\(pad(a.workspaceLabel, 22))\(pad(a.tabLabel, 22))\(pad(a.agent, 8))"
        out += "\(c)\(pad(a.status.rawValue, 9))\(ANSI.reset)\(pad(elapsed(since: a.since), 8))\(ANSI.dim)\(cwdTail)\(ANSI.reset)\n"
    }
    if !transitions.isEmpty {
        out += "\n\(ANSI.bold) transitions\(ANSI.reset)\n"
        for line in transitions.suffix(12) {
            out += " \(line)\n"
        }
    }
    out += "\n\(ANSI.dim) socket: \(socketPath) · ctrl-c to quit\(ANSI.reset)\n"
    print(out, terminator: "")
    fflush(stdout)
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - main loop

let bridge = HerdBridge(socketPath: socketPath)
var table: [HerdAgent] = []
var transitions: [String] = []

do {
    let stream = try await bridge.run()

    // Periodic redraw so the "for" column ticks even without events.
    let ticker = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            draw(agents: table, transitions: transitions)
        }
    }
    defer { ticker.cancel() }

    for await update in stream {
        switch update {
        case .hydrated(let list):
            table = list
        case .transition(let agent, let from):
            if let i = table.firstIndex(where: { $0.paneID == agent.paneID }) {
                table[i] = agent
            }
            let c = ANSI.color(agent.status)
            transitions.append(
                "\(ANSI.dim)\(timestamp())\(ANSI.reset) \(agent.workspaceLabel)/\(agent.tabLabel) [\(agent.agent)] \(from.rawValue) → \(c)\(agent.status.rawValue)\(ANSI.reset)"
            )
            // Re-sort: attention order (blocked first).
            let rank: [AgentStatus: Int] = [.blocked: 0, .done: 1, .working: 2, .idle: 3, .unknown: 4]
            table.sort {
                let l = rank[$0.status, default: 5], r = rank[$1.status, default: 5]
                if l != r { return l < r }
                if $0.workspaceLabel != $1.workspaceLabel { return $0.workspaceLabel < $1.workspaceLabel }
                return $0.paneID < $1.paneID
            }
        }
        draw(agents: table, transitions: transitions)
    }
} catch {
    FileHandle.standardError.write(Data("herd: \(error)\n".utf8))
    exit(1)
}
