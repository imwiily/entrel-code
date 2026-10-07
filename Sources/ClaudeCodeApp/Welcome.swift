import SwiftUI

// MARK: - Recent folders

enum Recents {
    private static let key = "recentFolders"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: key)
    }
}

enum Mode: String { case chat, terminal }

// MARK: - Welcome

struct WelcomeView: View {
    let open: (URL) -> Void
    let choose: () -> Void
    private let recents = Recents.all
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 22) {
            EntrelMark()
                .padding(16)
                .frame(width: 80, height: 80)
                .card(background: Theme.surfaceLowest, border: Theme.border.opacity(0.9), radius: 22)
                .background(RoundedRectangle(cornerRadius: 22).fill(Theme.brand.opacity(0.18)).blur(radius: 24))

            VStack(spacing: 6) {
                Text("Abra um projeto para começar")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Conecte o Entrel Code a qualquer repositório local com o Claude Code CLI.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 10) {
                Button(action: choose) {
                    Label("Abrir Projeto…", systemImage: "folder")
                        .padding(.horizontal, 8).padding(.vertical, 3)
                }
                .buttonStyle(.brand)
                .keyboardShortcut("o")
                Text("ou arraste uma pasta para esta janela")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("RECENTES")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    ForEach(recents, id: \.path) { url in
                        RecentRow(url: url) { open(url) }
                    }
                }
                .padding(.bottom, 4)
                .frame(maxWidth: 420)
                .card(background: Theme.surfaceLowest, radius: 12)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Theme.brand.opacity(0.06))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                var isDirectory: ObjCBool = false
                guard let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return }
                DispatchQueue.main.async { open(url) }
            }
            return true
        }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(hovering ? Theme.surfaceHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Titlebar status: what the agent is doing, with a pulsing terracotta bead while it works.
struct AgentStatusPill: View {
    @ObservedObject var chat: ChatSession
    let mode: Mode

    var body: some View {
        HStack(spacing: 7) {
            StatusBead(color: color, pulsing: chat.busy && mode == .chat, size: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border))
        .frame(maxWidth: 280)
    }

    private var text: String {
        if mode == .terminal { return "Terminal" }
        if !chat.running { return chat.loadingHistory ? "Carregando…" : "Encerrado" }
        guard chat.busy else { return "Pronto" }
        return chat.activity.isEmpty ? "Trabalhando…" : chat.activity
    }

    private var color: Color {
        if mode == .terminal { return Theme.textSecondary }
        if !chat.running { return chat.loadingHistory ? Theme.textMuted : Theme.error }
        return chat.busy ? Theme.brand : Theme.textMuted
    }
}
