import AppKit
import SwiftTerm
import SwiftUI

@main
struct ClaudeCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Claude Code") {
            ContentView()
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 960, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

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

// MARK: - Terminal session

final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var directory: URL?
    @Published var running = false
    @Published var title = ""
    @Published private(set) var terminalView: LocalProcessTerminalView?

    func open(_ url: URL) {
        directory = url
        restart()
    }

    func restart() {
        guard let directory else { return }
        stop()

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.processDelegate = self
        view.optionAsMetaKey = true
        view.getTerminal().changeHistorySize(10_000)
        installScrollMonitor(for: view)

        // GUI apps don't inherit the shell PATH, so run claude through a login shell
        // and make sure the usual install locations are reachable.
        let home = NSHomeDirectory()
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        env.removeAll { $0.hasPrefix("PATH=") || $0.hasPrefix("LANG=") }
        env.append("PATH=\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        env.append("LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")")

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(
            executable: shell,
            args: ["-l", "-c", "exec claude"],
            environment: env,
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory.path
        )

        terminalView = view
        running = true
        title = directory.lastPathComponent
    }

    func stop() {
        if running { terminalView?.terminate() }
        running = false
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: Scrolling

    // SwiftTerm's scrollWheel ignores trackpad precise deltas and does nothing while
    // the app is on the alternate screen, so handle wheel events ourselves.
    private var scrollMonitor: Any?
    private var pendingScroll: CGFloat = 0

    private func installScrollMonitor(for view: LocalProcessTerminalView) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
            guard let self, let view, event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            else { return event }
            self.handleScroll(event, in: view)
            return nil
        }
    }

    private func handleScroll(_ event: NSEvent, in view: LocalProcessTerminalView) {
        let terminal = view.getTerminal()
        let cellHeight = max(view.bounds.height / CGFloat(max(terminal.rows, 1)), 1)
        pendingScroll += event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / cellHeight
            : event.scrollingDeltaY
        let lines = Int(pendingScroll)
        guard lines != 0 else { return }
        pendingScroll -= CGFloat(lines)
        let up = lines > 0
        let count = abs(lines)

        guard terminal.isCurrentBufferAlternate else {
            up ? view.scrollUp(lines: count) : view.scrollDown(lines: count)
            return
        }

        if terminal.mouseMode != .off {
            // Forward as mouse wheel events so the app scrolls its own content.
            let point = view.convert(event.locationInWindow, from: nil)
            let col = min(max(Int(point.x / max(view.bounds.width / CGFloat(terminal.cols), 1)), 0), terminal.cols - 1)
            let row = min(max(Int((view.bounds.height - point.y) / cellHeight), 0), terminal.rows - 1)
            let flags = terminal.encodeButton(
                button: up ? 4 : 5, release: false,
                shift: event.modifierFlags.contains(.shift),
                meta: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control))
            for _ in 0..<count { terminal.sendEvent(buttonFlags: flags, x: col, y: row) }
        } else {
            // No mouse reporting: translate to arrow keys, like most terminals do.
            let key = terminal.applicationCursor ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
            view.send(txt: String(repeating: key, count: count))
        }
    }

    // LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { if !title.isEmpty { self.title = title } }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            guard source === self.terminalView else { return }
            self.running = false
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

// MARK: - Views

enum Mode: String { case chat, terminal }

struct ContentView: View {
    @StateObject private var session = TerminalSession()
    @StateObject private var chat = ChatSession()
    @State private var directory: URL?
    @AppStorage("mode") private var mode: Mode = .chat

    var body: some View {
        Group {
            if directory == nil {
                WelcomeView(open: open, choose: chooseFolder)
            } else if mode == .chat {
                ChatView(session: chat)
                    .overlay(alignment: .bottom) {
                        if !chat.running { endedBanner(restart: chat.restart).padding(.bottom, 70) }
                    }
            } else if let view = session.terminalView {
                TerminalHost(view: view)
                    .id(ObjectIdentifier(view))
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(alignment: .bottom) {
                        if !session.running { endedBanner(restart: session.restart) }
                    }
            }
        }
        .navigationTitle(directory?.lastPathComponent ?? "Claude Code")
        .navigationSubtitle(directory?.path ?? "")
        .toolbar {
            if directory != nil {
                ToolbarItem(placement: .principal) {
                    Picker("Modo", selection: $mode) {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(Mode.chat)
                        Label("Terminal", systemImage: "terminal").tag(Mode.terminal)
                    }
                    .pickerStyle(.segmented)
                    .help("Alternar entre chat e terminal")
                }
                ToolbarItemGroup {
                    Button(action: chooseFolder) {
                        Label("Abrir pasta", systemImage: "folder")
                    }
                    .help("Abrir outra pasta")
                    Button(action: restartCurrent) {
                        Label(mode == .chat ? "Nova conversa" : "Reiniciar",
                              systemImage: mode == .chat ? "square.and.pencil" : "arrow.clockwise")
                    }
                    .help(mode == .chat ? "Começar uma nova conversa" : "Reiniciar o Claude Code")
                }
            }
        }
        .onChange(of: mode) { _ in startCurrentIfNeeded() }
        .onDisappear {
            session.stop()
            chat.stop()
        }
    }

    private func open(_ url: URL) {
        Recents.add(url)
        directory = url
        session.stop()
        chat.stop()
        startCurrentIfNeeded()
    }

    // Each mode runs its own Claude Code process, started the first time it is shown.
    private func startCurrentIfNeeded() {
        guard let directory else { return }
        switch mode {
        case .chat:
            if chat.directory != directory { chat.open(directory) }
        case .terminal:
            if session.directory != directory { session.open(directory) }
        }
    }

    private func restartCurrent() {
        mode == .chat ? chat.restart() : session.restart()
    }

    private func endedBanner(restart: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text("O Claude Code foi encerrado.")
            Button("Reiniciar", action: restart)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 20)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Abrir"
        panel.message = "Escolha a pasta do projeto onde o Claude Code vai rodar"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }
}

struct WelcomeView: View {
    let open: (URL) -> Void
    let choose: () -> Void
    private let recents = Recents.all

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkle")
                .font(.system(size: 48))
                .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
            Text("Claude Code")
                .font(.largeTitle.weight(.semibold))
            Button(action: choose) {
                Label("Abrir pasta…", systemImage: "folder")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .keyboardShortcut("o")

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recentes").font(.headline).foregroundStyle(.secondary)
                    ForEach(recents, id: \.path) { url in
                        Button { open(url) } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 360)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
