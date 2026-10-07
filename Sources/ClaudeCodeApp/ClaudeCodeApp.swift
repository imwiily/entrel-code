import AppKit
import SwiftTerm
import SwiftUI

@main
struct ClaudeCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Each window (or tab) holds one project folder and its own conversation.
        WindowGroup("Entrel Code", id: "main", for: URL.self) { $folder in
            ContentView(directory: $folder)
                .frame(minWidth: 720, minHeight: 460)
                .preferredColorScheme(.dark)
                .tint(Theme.brand)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { AppCommands() }
    }
}

// MARK: - Menus and shortcuts

struct WindowActions {
    var directory: URL?
    var isChat: Bool
    var newConversation: () -> Void
    var openFolder: () -> Void
    var exportConversation: () -> Void
    var find: () -> Void
    var showChanges: () -> Void
}

private struct WindowActionsKey: FocusedValueKey { typealias Value = WindowActions }

extension FocusedValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @AppStorage("fontScale") private var fontScale = 1.0

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nova conversa") { actions?.newConversation() }
                .keyboardShortcut("n")
                .disabled(actions?.isChat != true)
            Button("Nova aba") {
                Tabbing.pendingParent = NSApp.keyWindow
                if let directory = actions?.directory { openWindow(id: "main", value: directory) }
                else { openWindow(id: "main") }
            }
            .keyboardShortcut("t")
            Button("Nova janela") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Abrir pasta…") { actions?.openFolder() }
                .keyboardShortcut("o")
            Button("Exportar conversa…") { actions?.exportConversation() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.isChat != true)
        }
        CommandGroup(after: .textEditing) {
            Button("Buscar na conversa") { actions?.find() }
                .keyboardShortcut("f")
                .disabled(actions?.isChat != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Aumentar texto") { fontScale = min(fontScale + 0.1, 2) }
                .keyboardShortcut("+")
            Button("Diminuir texto") { fontScale = max(fontScale - 0.1, 0.7) }
                .keyboardShortcut("-")
            Button("Tamanho padrão") { fontScale = 1 }
                .keyboardShortcut("0")
            Divider()
            Button("Alterações do Git") { actions?.showChanges() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.directory == nil)
        }
    }
}

/// Makes the next window that appears a tab of the window that asked for it.
enum Tabbing {
    static weak var pendingParent: NSWindow?
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, let parent = Tabbing.pendingParent, parent !== window else { return }
            Tabbing.pendingParent = nil
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Entrel Code is dark-only; this also covers menus, sheets and panels.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.requestAuthorization()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Terminal session

final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var directory: URL?
    @Published var running = false
    @Published var title = ""
    /// Extra shell-quoted arguments for `claude`, e.g. a slash command to run on launch.
    var arguments = ""
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
        view.nativeBackgroundColor = NSColor(srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x0E / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xED / 255, alpha: 1)
        view.caretColor = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x45 / 255, alpha: 1)
        view.selectedTextBackgroundColor = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x45 / 255, alpha: 0.35)
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
            args: ["-l", "-c", arguments.isEmpty ? "exec claude" : "exec claude \(arguments)"],
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

struct ContentView: View {
    @Binding var directory: URL?
    @StateObject private var session = TerminalSession()
    @StateObject private var chat = ChatSession()
    @AppStorage("mode") private var mode: Mode = .chat
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var findVisible = false
    @State private var showChanges = false

    var body: some View {
        main
            .background(Theme.canvas)
            .navigationTitle(directory?.lastPathComponent ?? "Entrel Code")
            .navigationSubtitle(directory?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
            .toolbar { toolbar }
            .toolbarBackground(Theme.surfaceLowest, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .onAppear(perform: startCurrentIfNeeded)
            .onChange(of: mode) { _ in startCurrentIfNeeded() }
            .onChange(of: directory) { _ in startCurrentIfNeeded() }
            .onChange(of: chat.historyRequests) { _ in columns = .all }
            .sheet(item: $chat.terminalCommand, onDismiss: chat.reconnect) { request in
                if let directory {
                    CommandTerminalSheet(command: request.command, directory: directory) {
                        chat.terminalCommand = nil
                    }
                }
            }
            .sheet(isPresented: $showChanges) {
                if let directory { GitChangesView(directory: directory) }
            }
            .focusedSceneValue(\.windowActions, actions)
            .background(WindowAccessor())
            .onDisappear {
                session.stop()
                chat.stop()
            }
    }

    @ViewBuilder private var main: some View {
        if let directory {
            if mode == .chat {
                NavigationSplitView(columnVisibility: $columns) {
                    ConversationSidebar(directory: directory, session: chat)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
                } detail: {
                    chatDetail
                }
            } else {
                terminalDetail
            }
        } else {
            WelcomeView(open: open, choose: chooseFolder)
        }
    }

    private var chatDetail: some View {
        ChatView(session: chat, findVisible: $findVisible)
            .overlay(alignment: .bottom) {
                if !chat.running && !chat.loadingHistory {
                    endedBanner(restart: chat.reconnect).padding(.bottom, 90)
                }
            }
    }

    @ViewBuilder private var terminalDetail: some View {
        if let view = session.terminalView {
            TerminalHost(view: view)
                .id(ObjectIdentifier(view))
                .padding(8)
                .background(Theme.canvas)
                .overlay(alignment: .bottom) {
                    if !session.running { endedBanner(restart: session.restart) }
                }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            EntrelMark().frame(width: 18, height: 18).help("Entrel Code")
        }
        if directory != nil {
            ToolbarItem(placement: .principal) {
                AgentStatusPill(chat: chat, mode: mode)
            }
            ToolbarItemGroup {
                Picker("Modo", selection: $mode) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(Mode.chat)
                    Label("Terminal", systemImage: "terminal").tag(Mode.terminal)
                }
                .pickerStyle(.segmented)
                .help("Alternar entre chat e terminal")
                Button { showChanges = true } label: {
                    Label("Alterações", systemImage: "plusminus.circle")
                }
                .help("Arquivos alterados no projeto (⇧⌘G)")
                Button(action: chooseFolder) {
                    Label("Abrir pasta", systemImage: "folder")
                }
                .help("Abrir outra pasta (⌘O)")
                Button(action: restartCurrent) {
                    Label(mode == .chat ? "Nova conversa" : "Reiniciar",
                          systemImage: mode == .chat ? "square.and.pencil" : "arrow.clockwise")
                }
                .help(mode == .chat ? "Começar uma nova conversa (⌘N)" : "Reiniciar o Claude Code")
                Button { chat.openTerminal("/config") } label: {
                    Label("Configurações", systemImage: "gearshape")
                }
                .help("Configurações do Claude Code")
            }
        }
    }

    private var actions: WindowActions {
        WindowActions(
            directory: directory,
            isChat: directory != nil && mode == .chat,
            newConversation: { chat.restart() },
            openFolder: chooseFolder,
            exportConversation: exportConversation,
            find: { findVisible = true },
            showChanges: { if directory != nil { showChanges = true } })
    }

    private func open(_ url: URL) {
        Recents.add(url)
        session.stop()
        chat.stop()
        directory = url
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

    private func exportConversation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Conversa \(directory?.lastPathComponent ?? "Claude").md"
        if panel.runModal() == .OK, let url = panel.url {
            try? chat.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func endedBanner(restart: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            StatusBead(color: Theme.error)
            Text("O Claude Code foi encerrado.").font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
            Button("Reiniciar", action: restart)
                .buttonStyle(.brand)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .card(background: Theme.elevated, border: Theme.subtle, radius: 12)
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
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

/// Runs an interactive Claude Code command (like /login or /config) in a terminal
/// over the chat. Closing it reconnects the chat so new settings take effect.
struct CommandTerminalSheet: View {
    let command: String
    let directory: URL
    let close: () -> Void
    @StateObject private var session = TerminalSession()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("›").foregroundStyle(Theme.brand)
                Text(command.isEmpty ? "claude" : command)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Text(session.running ? "Use o teclado no terminal; Esc volta nos menus."
                                     : "O comando terminou.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Concluir", action: close)
                    .buttonStyle(.brand)
                    .keyboardShortcut("w", modifiers: .command)
                    .help("Fechar e voltar ao chat (⌘W)")
            }
            .padding(12)
            .background(Theme.surfaceLowest)
            Rectangle().fill(Theme.divider).frame(height: 1)
            if let view = session.terminalView {
                TerminalHost(view: view)
                    .id(ObjectIdentifier(view))
                    .padding(8)
                    .background(Theme.canvas)
            } else {
                Spacer()
            }
        }
        .background(Theme.canvas)
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            session.arguments = command.isEmpty ? "" : ChatSession.shellQuote(command)
            session.open(directory)
        }
        .onDisappear(perform: session.stop)
    }
}

