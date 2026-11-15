import SwiftUI
import AppKit

/// Settings › Setup: what 23 needs, with one-click installs.
struct SetupSettings: View {
    @ObservedObject private var setup = Setup.shared
    @State private var openLog: String?

    var body: some View {
        SettingsGroup(title: "Needed", note: setup.essentialsReady ? "23 is ready." : "23 needs these two to work. Everything runs on this Mac.") {
            ForEach(setup.items.filter(\.required)) { row($0) }
        }
        SettingsGroup(title: "Optional", note: "Each comes from its project's official source. Downloads are checked against known checksums, and a file that doesn't match is deleted. Homebrew's installer asks for your Mac password in Terminal; nothing else does.") {
            ForEach(setup.items.filter { !$0.required }) { row($0) }
        }
        HStack {
            Button("Check again") { Task { await setup.refresh() } }
            Spacer()
        }
        .controlSize(.small)
        .task { await setup.refresh() }
    }

    @ViewBuilder private func row(_ item: Setup.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                icon(item.status).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                        if !item.size.isEmpty { Text(item.size).font(.caption).foregroundStyle(.tertiary) }
                    }
                    Text(item.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    statusText(item)
                }
                Spacer(minLength: 8)
                action(item)
            }
            if case .missing = item.status {
                HStack(spacing: 6) {
                    Text("By hand: " + item.manual).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    if let l = item.link, let u = URL(string: l) { Link("More", destination: u).font(.caption) }
                }
                .padding(.leading, 28)
            }
            if openLog == item.id, let lines = setup.log[item.id], !lines.isEmpty {
                ScrollView { Text(lines.suffix(60).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140).padding(.leading, 28)
            }
        }
    }

    @ViewBuilder private func statusText(_ item: Setup.Item) -> some View {
        switch item.status {
        case .ok(let s): Text(s).font(.caption).foregroundStyle(.secondary)
        case .working(let s): Text(s).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .failed(let s): Text(s).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    @ViewBuilder private func icon(_ s: Setup.Status) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Ready")
        case .working: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red).accessibilityLabel("Problem")
        default: Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityLabel("Not installed")
        }
    }

    @ViewBuilder private func action(_ item: Setup.Item) -> some View {
        HStack(spacing: 6) {
            if setup.log[item.id] != nil {
                Button { openLog = openLog == item.id ? nil : item.id } label: { Image(systemName: "text.alignleft") }
                    .buttonStyle(.borderless).help("Show what the installer did")
            }
            switch item.status {
            case .working: Button("Stop") { setup.cancel() }.controlSize(.small)
            case .ok: EmptyView()
            default:
                Button(label(item)) { setup.install(item.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent).tint(item.required ? DS.accent : .gray)
            }
        }
    }

    private func label(_ item: Setup.Item) -> String {
        switch item.id {
        case "ollama": return Setup.brew != nil ? "Install" : "Download"
        case "model": return "Download"
        case "homebrew": return "Open installer"
        case "claude", "tailscale": return "Get it"
        case "access": return "Allow"
        default: return "Install"
        }
    }
}
