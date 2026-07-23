import AppKit
import SwiftUI
import HerdBridge

// herd-notch — Phase-1 prototype, built with SwiftPM (no Xcode needed).
// A borderless floating panel at the notch position showing the live
// attention queue. Same NSPanel technique as boring.notch; the view and
// model port into the fork unchanged.

// MARK: - observable model

@MainActor
final class HerdModel: ObservableObject {
    @Published var agents: [HerdAgent] = []
    @Published var connected = false

    let bridge: HerdBridge

    init(socketPath: String) {
        bridge = HerdBridge(socketPath: socketPath)
    }

    func start() {
        Task {
            do {
                let stream = try await bridge.run()
                connected = true
                for await update in stream {
                    switch update {
                    case .hydrated(let list):
                        agents = list
                    case .transition(let agent, _):
                        if let i = agents.firstIndex(where: { $0.paneID == agent.paneID }) {
                            agents[i] = agent
                        }
                        agents.sort {
                            let l = HerdBridge.attentionRank($0), r = HerdBridge.attentionRank($1)
                            if l != r { return l < r }
                            if $0.workspaceLabel != $1.workspaceLabel { return $0.workspaceLabel < $1.workspaceLabel }
                            return $0.paneID < $1.paneID
                        }
                    }
                }
                connected = false
            } catch {
                connected = false
            }
        }
    }

    func focus(_ agent: HerdAgent) {
        Task { await bridge.focus(paneID: agent.paneID) }
    }

    func ack(_ agent: HerdAgent) {
        Task { await bridge.ack(paneID: agent.paneID) }
    }
}

// MARK: - views

func statusColor(_ s: AgentStatus) -> Color {
    switch s {
    case .working: return .orange
    case .blocked: return .red
    case .done: return .green
    case .idle: return .secondary
    case .unknown: return .gray
    }
}

func weatherGlyph(_ agents: [HerdAgent]) -> String {
    if agents.contains(where: { $0.status == .blocked }) { return "⛈" }
    if agents.contains(where: { $0.status == .working }) { return "⛅" }
    return "☀"
}

struct AgentRow: View {
    let agent: HerdAgent
    let onFocus: () -> Void
    let onAck: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agent.needsAck ? .green : statusColor(agent.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(agent.workspaceLabel) / \(agent.tabLabel)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(agent.needsAck ? "\(agent.agent) · finished ✔" : "\(agent.agent) · \(agent.status.rawValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(agent.needsAck ? .green : statusColor(agent.status))
            }
            Spacer(minLength: 4)
            if agent.needsAck {
                Button(action: onAck) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Acknowledge")
            }
            Text(elapsedText(agent.since))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.gray)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private func elapsedText(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}

struct HerdView: View {
    @ObservedObject var model: HerdModel

    private var counts: String {
        let byStatus = Dictionary(grouping: model.agents, by: \.status).mapValues(\.count)
        var parts: [String] = []
        if let b = byStatus[.blocked] { parts.append("\(b) blocked") }
        let acks = model.agents.filter(\.needsAck).count
        if acks > 0 { parts.append("\(acks) finished") }
        if let w = byStatus[.working] { parts.append("\(w) working") }
        if let i = byStatus[.idle] { parts.append("\(i) idle") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(weatherGlyph(model.agents))
                Text("herd").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(model.connected ? counts : "connecting…")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .foregroundStyle(.white)

            Divider().overlay(Color.white.opacity(0.15))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.agents) { agent in
                        AgentRow(
                            agent: agent,
                            onFocus: { model.focus(agent) },
                            onAck: { model.ack(agent) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 380, height: 320)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - notch window

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel!
    var model: HerdModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let socketPath = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? "\(NSHomeDirectory())/.config/herdr/herdr.sock"
        model = HerdModel(socketPath: socketPath)
        model.start()

        let size = NSSize(width: 380, height: 320)
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HerdView(model: model))

        positionAtNotch()
        panel.orderFrontRegardless()
    }

    /// Top-center of the main screen, hanging just below the notch/menu-bar.
    private func positionAtNotch() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let size = panel.frame.size
        let x = f.midX - size.width / 2
        let y = f.maxY - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
