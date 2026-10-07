import SwiftUI
import UniformTypeIdentifiers

let accent = Theme.brand

// MARK: - Environment

private struct FontScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
private struct ProjectDirectoryKey: EnvironmentKey { static let defaultValue: URL? = nil }

extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
    var projectDirectory: URL? {
        get { self[ProjectDirectoryKey.self] }
        set { self[ProjectDirectoryKey.self] = newValue }
    }
}

/// Text styles sized from the app's font scale (⌘+ / ⌘−) instead of fixed system sizes.
private struct ScaledFont: ViewModifier {
    @Environment(\.fontScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        let size: CGFloat
        var defaultWeight: Font.Weight = .regular
        switch style {
        case .largeTitle: size = 26
        case .title: size = 22
        case .title2: size = 17
        case .title3: size = 15
        case .headline: size = 13; defaultWeight = .semibold
        case .subheadline: size = 11
        case .callout: size = 12
        case .footnote, .caption, .caption2: size = 10
        default: size = 13
        }
        return content.font(.system(size: size * scale, weight: weight ?? defaultWeight, design: design))
    }
}

extension View {
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(style: style, weight: weight, design: design))
    }
}

// MARK: - Chat

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @Binding var findVisible: Bool
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var composerHeight: CGFloat = 20
    @State private var focusTrigger = 0
    @State private var selectedSuggestion = 0
    @State private var dismissedSuggestionsFor: String?
    @State private var dropTargeted = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @FocusState private var findFocused: Bool
    @AppStorage("fontScale") private var fontScale = 1.0

    var body: some View {
        VStack(spacing: 0) {
            if findVisible {
                findBar
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.loadingHistory {
                            HStack(spacing: 8) { StatusBead(pulsing: true); Text("Carregando conversa…") }
                                .scaledFont(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else if session.items.isEmpty {
                            emptyState
                        }
                        ForEach(session.items) { item in
                            ChatRow(item: item, revision: item.revision,
                                    highlighted: item.id == currentMatch, session: session)
                                .equatable()
                                .id(item.id)
                        }
                        if session.busy { activityRow }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 800)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.items.count) { _ in
                    if !findVisible { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: lastText) { _ in
                    if !findVisible { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.loadingHistory) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: currentMatch) { id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .scaledFont(.body)
        .environment(\.fontScale, fontScale)
        .environment(\.projectDirectory, session.directory)
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL else { return .systemAction }
            NSWorkspace.shared.open(url)
            return .handled
        })
        .background(Theme.canvas)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Theme.brand.opacity(0.06))
                    .overlay(Label("Solte para anexar", systemImage: "paperclip").scaledFont(.title3))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)
        .onChange(of: findVisible) { visible in
            if visible { findFocused = true } else { findQuery = ""; focusTrigger += 1 }
        }
    }

    private var lastText: Int {
        guard case .assistant(let text) = session.items.last?.kind else { return 0 }
        return text.count
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            EntrelMark()
                .padding(10)
                .frame(width: 48, height: 48)
                .card(background: Theme.surfaceLowest, radius: 14)
            VStack(spacing: 5) {
                Text("O que devemos construir?")
                    .scaledFont(.title3, weight: .medium).foregroundStyle(Theme.textPrimary)
                (Text("Trabalhando em ") + Text(session.directory?.lastPathComponent ?? "").foregroundColor(Theme.textPrimary)
                    + Text(session.projectFiles.isEmpty ? "" : " • \(session.projectFiles.count) arquivos"))
                    .scaledFont(.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 6) {
                hint("@", "mencionar arquivos")
                hint("/", "comandos")
                hint("⌘V", "colar imagens")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(text).scaledFont(.caption2).foregroundStyle(Theme.textMuted)
        }
    }

    private var activityRow: some View {
        HStack(spacing: 10) {
            StatusBead(pulsing: true, size: 7)
            Text("Agente trabalhando").scaledFont(.caption, weight: .medium).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(session.activity.isEmpty ? "Em execução…" : session.activity)
                .scaledFont(.caption2, design: .monospaced)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .card(background: Theme.surfaceLowest.opacity(0.7))
    }

    // MARK: Find

    private var matches: [UUID] {
        let query = findQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return session.items.filter { $0.searchText.localizedCaseInsensitiveContains(query) }.map(\.id)
    }

    private var currentMatch: UUID? {
        let list = matches
        guard findVisible, !list.isEmpty else { return nil }
        return list[min(findIndex, list.count - 1)]
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
            TextField("Buscar na conversa", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { moveMatch(by: NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1) }
                .onExitCommand { findVisible = false }
                .onChange(of: findQuery) { _ in findIndex = 0 }
            if !findQuery.isEmpty {
                Text(matches.isEmpty ? "Nenhum resultado" : "\(min(findIndex, matches.count - 1) + 1) de \(matches.count)")
                    .scaledFont(.caption2, design: .monospaced).foregroundStyle(Theme.textMuted)
            }
            Button { moveMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.isEmpty).help("Anterior (⇧Enter)")
            Button { moveMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.isEmpty).help("Próximo (Enter)")
            Button { findVisible = false } label: { Image(systemName: "xmark") }
                .help("Fechar (Esc)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surfaceLowest)
    }

    private func moveMatch(by step: Int) {
        let count = matches.count
        guard count > 0 else { return }
        findIndex = (min(findIndex, count - 1) + step + count) % count
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty { suggestionList }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        attachmentPill(attachment)
                    }
                    Button(action: chooseFiles) {
                        Label("Adicionar contexto", systemImage: "plus")
                            .scaledFont(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Anexar arquivos ou imagens")
                    Spacer(minLength: 0)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 14 * fontScale))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }
                        ComposerTextView(text: $draft, height: $composerHeight, isEnabled: session.running,
                                         fontSize: 14 * fontScale, focusTrigger: focusTrigger,
                                         onSubmit: send, onKey: handleKey, onPaste: handlePaste)
                            .frame(height: composerHeight)
                    }

                    if session.busy {
                        Button(action: session.interrupt) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(Theme.textPrimary)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.highlight))
                        }
                        .buttonStyle(.plain)
                        .help("Interromper (Esc)")
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(canSend ? Color.white : Theme.textMuted)
                            .background(RoundedRectangle(cornerRadius: 8).fill(canSend ? Theme.brand : Theme.highlight))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(session.busy ? "Enviar agora — o Claude considera a mensagem no meio da tarefa (Enter)"
                                       : "Enviar (Enter)")
                }
            }
            .padding(12)
            .card(background: Theme.elevated, border: Theme.subtle, radius: 14)
            .shadow(color: .black.opacity(0.55), radius: 18, y: 8)

            HStack(spacing: 4) {
                Text("Pressione").foregroundStyle(Theme.textMuted)
                KeyCap(text: "Return")
                Text("para enviar,").foregroundStyle(Theme.textMuted)
                KeyCap(text: "Shift + Return")
                Text("para nova linha").foregroundStyle(Theme.textMuted)
                Spacer(minLength: 12)
                StatusBar(session: session)
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 800)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private func attachmentPill(_ attachment: Attachment) -> some View {
        HStack(spacing: 6) {
            if case .image(let image, _, _) = attachment.kind {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 3))
            }
            ContextPill(text: attachment.name) {
                attachments.removeAll { $0.id == attachment.id }
            }
        }
    }

    private var placeholder: String {
        if !session.running { return "O Claude Code foi encerrado" }
        if session.busy { return "Escreva para orientar o Entrel enquanto ele trabalha…" }
        return "Peça ao Entrel para trabalhar neste projeto…"
    }

    private var canSend: Bool {
        session.running && !session.loadingHistory
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        session.send(draft, attachments: attachments)
        draft = ""
        attachments = []
        dismissedSuggestionsFor = nil
        focusTrigger += 1
    }

    // MARK: Suggestions (/commands and @files)

    private enum Suggestion: Identifiable {
        case command(SlashCommand)
        case file(String)
        var id: String {
            switch self {
            case .command(let command): return "/" + command.name
            case .file(let path): return "@" + path
            }
        }
    }

    /// The "@partial" being typed at the end of the draft, if any.
    private var mentionQuery: String? {
        guard let match = draft.firstMatch(of: #/(?:^|\s)@([^\s]*)$/#) else { return nil }
        return String(match.1)
    }

    private var suggestions: [Suggestion] {
        guard dismissedSuggestionsFor != draft else { return [] }
        if let query = mentionQuery?.lowercased() {
            let files = session.projectFiles
            let named = files.filter { ($0 as NSString).lastPathComponent.lowercased().hasPrefix(query) }
            let rest = query.isEmpty ? [] : files.filter {
                $0.lowercased().contains(query) && !($0 as NSString).lastPathComponent.lowercased().hasPrefix(query)
            }
            return (named.sorted { $0.count < $1.count } + rest.sorted { $0.count < $1.count })
                .prefix(8).map(Suggestion.file)
        }
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return [] }
        let query = draft.dropFirst().lowercased()
        let prefix = session.commands.filter { $0.name.lowercased().hasPrefix(query) }
        let contains = session.commands.filter {
            !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query)
        }
        return (prefix + contains).prefix(8).map(Suggestion.command)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { complete(suggestion) } label: {
                    suggestionLabel(suggestion)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(index == clampedSelection ? Theme.highlight : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .card(background: Theme.elevated, border: Theme.subtle, radius: 10)
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    @ViewBuilder private func suggestionLabel(_ suggestion: Suggestion) -> some View {
        switch suggestion {
        case .command(let command):
            HStack(spacing: 10) {
                Text("/\(command.name)").scaledFont(.callout, weight: .medium, design: .monospaced)
                    .foregroundStyle(Theme.textPrimary)
                if !command.argumentHint.isEmpty {
                    Text(command.argumentHint).scaledFont(.caption).foregroundStyle(.tertiary)
                }
                if command.opensTerminal {
                    Label("terminal", systemImage: "terminal")
                        .scaledFont(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .foregroundStyle(Theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.highlight))
                        .help("Abre numa janela de terminal por cima do chat")
                }
                Text(command.description)
                    .scaledFont(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        case .file(let path):
            HStack(spacing: 8) {
                Text("@").scaledFont(.callout, design: .monospaced).foregroundStyle(Theme.brand)
                Text((path as NSString).lastPathComponent).scaledFont(.callout, weight: .medium, design: .monospaced)
                    .foregroundStyle(Theme.textPrimary)
                Text((path as NSString).deletingLastPathComponent)
                    .scaledFont(.caption2, design: .monospaced).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
    }

    private var clampedSelection: Int { min(selectedSuggestion, max(suggestions.count - 1, 0)) }

    private func complete(_ suggestion: Suggestion) {
        switch suggestion {
        case .command(let command):
            draft = "/\(command.name) "
        case .file(let path):
            if let query = mentionQuery {
                draft = String(draft.dropLast(query.count + 1)) + "@\(path) "
            }
        }
        selectedSuggestion = 0
        focusTrigger += 1
    }

    private func handleKey(_ key: ComposerTextView.Key) -> Bool {
        let list = suggestions
        if list.isEmpty {
            if key == .escape && session.busy { session.interrupt(); return true }
            return false
        }
        switch key {
        case .up: selectedSuggestion = max(clampedSelection - 1, 0)
        case .down: selectedSuggestion = min(clampedSelection + 1, list.count - 1)
        case .tab, .enter:
            // Enter on a fully typed command sends it instead of completing again.
            if key == .enter, case .command(let command) = list[clampedSelection],
               command.name == draft.dropFirst() { return false }
            complete(list[clampedSelection])
        case .escape: dismissedSuggestionsFor = draft
        }
        return true
    }

    // MARK: Attachments

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = session.directory
        if panel.runModal() == .OK {
            attachments += panel.urls.map(Attachment.from(url:))
        }
    }

    private func handlePaste(_ pasteboard: NSPasteboard) -> Bool {
        guard let pasted = Attachment.from(pasteboard: pasteboard) else { return false }
        attachments += pasted
        return true
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let attachment = Attachment.from(url: url)
                    DispatchQueue.main.async { attachments.append(attachment) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let attachment = Attachment.image(from: data) else { return }
                    DispatchQueue.main.async { attachments.append(attachment) }
                }
            }
        }
        return true
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(session.models) { model in
                    Button {
                        session.setModel(model.value)
                    } label: {
                        if model.value == session.selectedModel {
                            Label("\(model.displayName) — \(model.description)", systemImage: "checkmark")
                        } else {
                            Text("\(model.displayName) — \(model.description)")
                        }
                    }
                }
            } label: {
                Label(modelName, systemImage: "cpu")
            }
            .help("Modelo")

            Menu {
                ForEach(PermissionModeOption.all) { mode in
                    Button {
                        session.setPermissionMode(mode.value)
                    } label: {
                        if mode.value == session.permissionMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Label(currentMode.title, systemImage: currentMode.symbol)
            }
            .help("Modo de permissão")

            Spacer()

            if session.contextTokens > 0 {
                HStack(spacing: 6) {
                    Capsule().fill(Theme.elevated)
                        .frame(width: 44, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(contextFraction > 0.8 ? Theme.error : Theme.brand)
                                .frame(width: 44 * contextFraction, height: 3)
                        }
                    Text("\(Int((contextFraction * 100).rounded()))% · \(Self.tokens(session.contextTokens)) / \(Self.tokens(session.contextWindow))")
                        .monospacedDigit()
                }
                .help("Quanto da janela de contexto do modelo esta conversa já ocupa")
            }
            if session.costUSD > 0 {
                Text(String(format: "US$ %.2f", session.costUSD))
                    .monospacedDigit()
                    .help("Custo estimado desta sessão, em preço de API")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.mini)
        .tint(Theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(Theme.textMuted)
    }

    private var modelName: String {
        session.models.first { $0.value == session.selectedModel }?.displayName
            ?? (session.selectedModel == "default" ? "Modelo padrão" : session.selectedModel)
    }

    private var currentMode: PermissionModeOption {
        PermissionModeOption.all.first { $0.value == session.permissionMode }
            ?? PermissionModeOption(value: session.permissionMode, title: session.permissionMode, symbol: "hand.raised")
    }

    private var contextFraction: Double {
        min(Double(session.contextTokens) / Double(max(session.contextWindow, 1)), 1)
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1f mil", Double(count) / 1000) : "\(count)"
    }
}

// MARK: - Rows

/// Equatable on the item's id and revision, so unchanged rows aren't re-rendered
/// every time a new message streams in.
private struct ChatRow: View, Equatable {
    let item: ChatItem
    let revision: Int
    let highlighted: Bool
    let session: ChatSession

    static func == (lhs: ChatRow, rhs: ChatRow) -> Bool {
        lhs.item.id == rhs.item.id && lhs.revision == rhs.revision && lhs.highlighted == rhs.highlighted
    }

    var body: some View {
        content
            .padding(highlighted ? 4 : 0)
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.brand, lineWidth: 1.5)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user(let message):
            UserBubble(message: message, session: session) { session.edit(item.id, newText: $0) }
        case .assistant(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AssistantBubble(text: text)
            }
        case .tool(let tool):
            ToolRow(tool: tool)
        case .permission(let permission):
            PermissionRow(permission: permission) { allow, always in
                session.answerPermission(item.id, allow: allow, always: always)
            }
        case .question(let questions, let answers):
            QuestionRow(questions: questions, answers: answers) { answers in
                session.answerQuestion(item.id, answers: answers)
            }
        case .agent(let agent):
            AgentRow(agent: agent)
        case .choice(let choice):
            ChoiceRow(choice: choice) { session.choose(item.id, value: $0) }
        case .terminalHint(let command):
            HStack(spacing: 10) {
                IconTile(symbol: "terminal", tint: Theme.brand)
                Text("\(command) é interativo e precisa do terminal.")
                    .scaledFont(.callout).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Abrir no terminal") { session.terminalCommand = TerminalCommand(command: command) }
                    .buttonStyle(.brand)
            }
            .padding(12)
            .card(background: Theme.brand.opacity(0.05), border: Theme.brand.opacity(0.4))
        case .notice(let text):
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "xmark", tint: Theme.errorText, background: Theme.hex(0x2A1416), border: Theme.hex(0x4A2326))
                Text(text)
                    .scaledFont(.caption, design: .monospaced)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .card(background: Theme.hex(0x1A1214), border: Theme.hex(0x3A2224))
        }
    }
}

/// The small rounded square holding an icon at the start of alert-like cards.
private struct IconTile: View {
    let symbol: String
    var tint = Theme.brand
    var background: Color?
    var border: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(background ?? tint.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border ?? tint.opacity(0.3)))
    }
}

private struct UserBubble: View {
    let message: ChatItem.UserMessage
    @ObservedObject var session: ChatSession
    let resend: (String) -> Void
    @State private var hovering = false
    @State private var editing = false
    @State private var editedText = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 80)
            if !editing && hovering && !message.local && !message.queued && !session.busy && session.running {
                Button {
                    editedText = message.text
                    editing = true
                } label: {
                    Image(systemName: "pencil").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Editar e reenviar a partir daqui")
            }
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.images.indices, id: \.self) { index in
                            Image(nsImage: message.images[index]).resizable().scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.subtle))
                        }
                    }
                }
                ForEach(message.files, id: \.self) { file in
                    ContextPill(text: file)
                }
                if editing {
                    editor
                } else if !message.text.isEmpty {
                    Text(MarkdownText.attributed(message.text, linkingFilesIn: session.directory, codeColor: Theme.brand))
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .card(background: Theme.elevated.opacity(0.9), border: Theme.subtle.opacity(0.6), radius: 12)
                }
                if message.queued {
                    Label("enviada durante a tarefa", systemImage: "clock")
                        .scaledFont(.caption2).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $editedText)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 320, minHeight: 60, maxHeight: 200)
                .padding(8)
                .card(background: Theme.elevated, border: Theme.brand.opacity(0.6), radius: 12)
            Text("A conversa continua a partir daqui, numa cópia. Alterações já feitas em arquivos não são desfeitas.")
                .scaledFont(.caption2).foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 360, alignment: .trailing)
            HStack {
                Button("Cancelar") { editing = false }
                    .buttonStyle(.ghost)
                Button("Reenviar") {
                    editing = false
                    resend(editedText)
                }
                .buttonStyle(.brand)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// A compact monospaced capsule for files and other context, with an optional ×.
struct ContextPill: View {
    let text: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.hex(0xEAEAEA))
                .lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Text("×").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.highlight))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
    }
}

/// An option row for choice and question cards.
private struct OptionRow: View {
    let label: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(selected ? Theme.brand : Theme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(Theme.textPrimary)
                    if !detail.isEmpty {
                        Text(detail).scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.brand.opacity(0.12) : hovering ? Theme.highlight : Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Theme.brand.opacity(0.4) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ChoiceRow: View {
    let choice: ChatItem.Choice
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(choice.title).scaledFont(.callout, weight: .semibold).foregroundStyle(Theme.textPrimary)
            if let selected = choice.selected {
                Label(choice.options.first { $0.value == selected }?.label ?? selected,
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.brand)
            } else {
                ForEach(choice.options, id: \.value) { option in
                    OptionRow(label: option.label, detail: option.detail, symbol: "circle", selected: false) {
                        pick(option.value)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(background: Theme.brand.opacity(0.05),
              border: Theme.brand.opacity(choice.selected == nil ? 0.4 : 0.18))
    }
}

private struct AssistantBubble: View {
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            MarkdownText(text)
                .foregroundStyle(Theme.textBody)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .card(background: Theme.surface, border: Theme.divider, radius: 12)
            CopyButton(text: text)
                .opacity(hovering ? 1 : 0)
            Spacer(minLength: 60)
        }
        .onHover { hovering = $0 }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .scaledFont(.caption)
                .foregroundStyle(copied ? Theme.successText : Theme.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copiado" : "Copiar")
    }
}

/// A tool call. Edits render as a diff card (file header, +/− badges, collapsible body);
/// everything else as a command line with its status and expandable output.
private struct ToolRow: View {
    let tool: ChatItem.Tool
    @State private var showOutput = false
    @State private var showDiff = true

    private var diffStats: (added: Int, removed: Int)? {
        if case .diff(_, _, let added, let removed) = tool.detail { return (added, removed) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.vertical, 9)

            if let detail = tool.detail, diffStats == nil || showDiff {
                Rectangle().fill(Theme.divider).frame(height: 1)
                ToolDetailView(detail: detail)
            }

            if showOutput, let result = tool.result, !result.isEmpty {
                Rectangle().fill(Theme.divider).frame(height: 1)
                ScrollView {
                    Text(result)
                        .scaledFont(.caption, design: .monospaced)
                        .foregroundStyle(Theme.hex(0xA5A5A9))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .background(Theme.hex(0x0A0A0C))
            }
        }
        .card()
        .contextMenu {
            if let path = tool.filePath {
                Button("Abrir arquivo") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Mostrar no Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Copiar caminho") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            if let result = tool.result, !result.isEmpty {
                Button("Copiar saída") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let stats = diffStats {
                Image(systemName: "doc.text").foregroundStyle(Theme.textSecondary)
                Text((tool.summary as NSString).lastPathComponent)
                    .scaledFont(.caption, weight: .medium, design: .monospaced)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                DiffStats(added: stats.added, removed: stats.removed)
            } else {
                Text("›").foregroundStyle(Theme.brand)
                Text(tool.name)
                    .scaledFont(.caption, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Theme.textPrimary)
                Text(tool.summary)
                    .scaledFont(.caption, design: .monospaced)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let path = tool.filePath, FileManager.default.fileExists(atPath: path) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Image(systemName: "arrow.up.forward.square").foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Abrir arquivo")
            }
            if diffStats != nil {
                Button(showDiff ? "Ocultar alterações" : "Ver alterações") { showDiff.toggle() }
                    .buttonStyle(.plain)
                    .scaledFont(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let result = tool.result, !result.isEmpty {
                Button(showOutput ? "Ocultar saída" : "Ver saída") { showOutput.toggle() }
                    .buttonStyle(.plain)
                    .scaledFont(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 5) {
            if tool.result == nil {
                StatusBead(pulsing: true, size: 6)
                Text("executando").foregroundStyle(Theme.textMuted)
            } else if tool.isError {
                StatusBead(color: Theme.error, size: 6)
                Text("erro").foregroundStyle(Theme.errorText)
            } else {
                StatusBead(color: Theme.success, size: 6)
                Text("ok").foregroundStyle(Theme.successText)
            }
        }
        .scaledFont(.caption2)
    }
}

private struct DiffStats: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            badge("+\(added)", text: Theme.successText, fill: Theme.hex(0x122418), border: Theme.hex(0x1E3A27))
            badge("−\(removed)", text: Theme.errorText, fill: Theme.hex(0x281313), border: Theme.hex(0x42201F))
        }
    }

    private func badge(_ value: String, text: Color, fill: Color, border: Color) -> some View {
        Text(value)
            .scaledFont(.caption2, design: .monospaced)
            .monospacedDigit()
            .foregroundStyle(text)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(border))
    }
}

private struct ToolDetailView: View {
    let detail: ToolDetail

    var body: some View {
        switch detail {
        case .markdown(let text):
            MarkdownText(text)
                .foregroundStyle(Theme.textBody)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeInset)
        case .diff(_, let lines, _, _):
            if lines.isEmpty {
                Text("Nenhuma alteração").scaledFont(.caption).foregroundStyle(Theme.textMuted)
                    .padding(12)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines.indices, id: \.self) { index in
                            DiffLineView(line: lines[index])
                        }
                    }
                    .padding(10)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
                .background(Theme.codeInset)
            }
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 8) {
            Text(marker)
                .fontWeight(.semibold)
                .foregroundStyle(markerColor)
                .frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(textColor)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .scaledFont(.caption, design: .monospaced)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(background))
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context, .gap: return ""
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: return Theme.success
        case .removed: return Theme.error
        case .context, .gap: return Theme.textMuted
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .added: return Theme.successText
        case .removed: return Theme.errorText
        case .context: return Theme.hex(0xA5A5A9)
        case .gap: return Theme.textMuted
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Theme.addedBackground
        case .removed: return Theme.removedBackground
        case .context, .gap: return .clear
        }
    }
}

/// The approval gate: terracotta border, the action in a monospaced inset,
/// and Deny / Allow once / Always allow.
private struct PermissionRow: View {
    let permission: ChatItem.Permission
    let answer: (_ allow: Bool, _ always: Bool) -> Void

    private var isPlan: Bool { permission.tool == "ExitPlanMode" }
    private var pending: Bool { permission.state == .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: isPlan ? "list.bullet.clipboard" : "exclamationmark.triangle")
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(isPlan ? "Plano pronto para aprovação" : "Permissão necessária")
                            .scaledFont(.caption, weight: .semibold)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(isPlan ? "PLANO" : "SOLICITAÇÃO")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Theme.brand)
                    }
                    Text(isPlan ? "Revise o plano antes de o Entrel começar:" : "Entrel quer usar \(permission.tool):")
                        .scaledFont(.caption).foregroundStyle(Theme.hex(0xA5A5A9))
                    if !permission.summary.isEmpty && !isPlan {
                        Text(permission.summary)
                            .scaledFont(.caption, design: .monospaced)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .card(background: Theme.surfaceLowest.opacity(0.9), radius: 8)
                    }
                }
            }
            if let detail = permission.detail {
                ToolDetailView(detail: detail)
                    .card(background: Theme.codeInset, radius: 8)
            }
            Rectangle().fill(Theme.brand.opacity(0.2)).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                switch permission.state {
                case .pending:
                    Button(isPlan ? "Continuar planejando" : "Negar") { answer(false, false) }
                        .buttonStyle(.ghost)
                    if isPlan {
                        Button("Aprovar plano") { answer(true, false) }.buttonStyle(.brand)
                    } else {
                        Button("Permitir uma vez") { answer(true, false) }.buttonStyle(.elevated)
                        Button("Sempre permitir") { answer(true, true) }.buttonStyle(.brand)
                    }
                case .allowed:
                    resolved(isPlan ? "Plano aprovado" : "Permitido uma vez", color: Theme.success)
                case .allowedAlways:
                    resolved("Sempre permitido", color: Theme.success)
                case .denied:
                    resolved(isPlan ? "Plano recusado" : "Negado", color: Theme.error)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(background: Theme.brand.opacity(pending ? 0.05 : 0.02),
              border: Theme.brand.opacity(pending ? 0.4 : 0.15))
    }

    private func resolved(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            StatusBead(color: color, size: 6)
            Text(text).scaledFont(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct AgentRow: View {
    let agent: ChatItem.Agent
    @State private var showSteps = true
    @State private var showPrompt = false
    @State private var showResult = false

    private var running: Bool { agent.result == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBead(color: running ? Theme.brand : agent.isError ? Theme.error : Theme.success,
                           pulsing: running, size: 7)
                Text("Subagente").scaledFont(.caption, weight: .semibold).foregroundStyle(Theme.textPrimary)
                tag(agent.type, color: Theme.brand)
                if agent.background { tag("segundo plano", color: Theme.textSecondary) }
                Text(agent.description).scaledFont(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                if !agent.steps.isEmpty {
                    Button { showSteps.toggle() } label: {
                        Text("\(agent.steps.count) passos \(showSteps ? "▴" : "▾")")
                            .scaledFont(.caption2, design: .monospaced)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.bottom, 2)

            if running && !agent.progress.isEmpty {
                Text(agent.progress).scaledFont(.caption2, design: .monospaced).foregroundStyle(Theme.textMuted)
            }

            Rectangle().fill(Theme.divider).frame(height: 1)

            disclosure("Instruções", isOn: $showPrompt) {
                Text(agent.prompt).scaledFont(.caption).foregroundStyle(Theme.textBody)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showSteps && !agent.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agent.steps.indices, id: \.self) { index in
                        switch agent.steps[index] {
                        case .text(let text):
                            MarkdownText(text)
                                .scaledFont(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        case .tool(let tool):
                            ToolRow(tool: tool)
                        }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.brand.opacity(0.35)).frame(width: 2)
                }
            }

            if let result = agent.result, !result.isEmpty {
                disclosure("Relatório final", isOn: $showResult) {
                    MarkdownText(result).foregroundStyle(Theme.textBody)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(background: Theme.surfaceLowest.opacity(0.7))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.25)))
    }

    private func disclosure<Content: View>(_ title: String, isOn: Binding<Bool>,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isOn.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Text(isOn.wrappedValue ? "▾" : "›").foregroundStyle(Theme.brand)
                    Text(title)
                }
                .scaledFont(.caption, weight: .medium)
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            if isOn.wrappedValue { content() }
        }
    }
}

// MARK: - Conversation sidebar

struct ConversationSidebar: View {
    let directory: URL
    @ObservedObject var session: ChatSession
    @State private var sessions: [SessionSummary] = []
    @State private var search = ""
    @State private var renaming: SessionSummary?
    @State private var newTitle = ""
    @State private var deleting: SessionSummary?

    var body: some View {
        List(selection: Binding(
            get: { session.sessionID },
            set: { id in if let id, id != session.sessionID { session.resume(id) } })) {
            Section {
                ForEach(filtered) { summary in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(summary.date.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.vertical, 3)
                    .tag(summary.id)
                    .contextMenu {
                        Button("Renomear…") {
                            newTitle = summary.title
                            renaming = summary
                        }
                        Button("Apagar…", role: .destructive) { deleting = summary }
                    }
                }
            } header: {
                Text("CONVERSAS")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .searchable(text: $search, placement: .sidebar, prompt: "Buscar conversas")
        .safeAreaInset(edge: .top) {
            Button { session.restart() } label: {
                Label("Nova conversa", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.elevated)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
        }
        .task(id: reloadKey) { await reload() }
        .alert("Renomear conversa", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newTitle)
            Button("Salvar") {
                if let renaming { CustomTitles.set(newTitle, for: renaming.id) }
                renaming = nil
                Task { await reload() }
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Apagar esta conversa?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { summary in
            Button("Mover para o Lixo", role: .destructive) {
                Transcripts.delete(summary.id, in: directory)
                if summary.id == session.sessionID { session.restart() }
                deleting = nil
                Task { await reload() }
            }
        } message: { summary in
            Text("“\(summary.title)” vai para o Lixo.")
        }
    }

    private var filtered: [SessionSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    // Reload when the conversation changes or a turn finishes (new titles and dates).
    private var reloadKey: String { "\(directory.path)|\(session.sessionID ?? "")|\(session.busy)" }

    private func reload() async {
        let directory = directory
        sessions = await Task.detached { Transcripts.list(for: directory, limit: 200) }.value
    }
}

private struct QuestionRow: View {
    let questions: [ChatItem.Question]
    let answers: [String: String]?
    let submit: ([String: String]?) -> Void

    @State private var selected: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]

    private var pending: Bool { answers == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(questions.indices, id: \.self) { index in
                questionView(index)
            }
            if pending {
                Rectangle().fill(Theme.brand.opacity(0.2)).frame(height: 1)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Pular") { submit(nil) }.buttonStyle(.ghost)
                    Button("Responder") { submit(collectedAnswers) }
                        .buttonStyle(.brand)
                        .disabled(!isComplete)
                }
            } else if answers?.isEmpty == true {
                Text("Pergunta ignorada").scaledFont(.caption).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(background: Theme.brand.opacity(pending ? 0.05 : 0.02), border: Theme.brand.opacity(pending ? 0.4 : 0.15))
    }

    @ViewBuilder private func questionView(_ index: Int) -> some View {
        let q = questions[index]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !q.header.isEmpty {
                    Text(q.header.uppercased())
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Theme.brand)
                }
                if q.multiSelect && pending {
                    Text("Escolha uma ou mais").scaledFont(.caption2).foregroundStyle(Theme.textMuted)
                }
            }
            Text(q.question).scaledFont(.callout, weight: .semibold).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let answer = answers?[q.question] {
                Label(answer, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.brand)
            } else if pending {
                ForEach(q.options.indices, id: \.self) { optionIndex in
                    optionButton(q.options[optionIndex], question: index, multi: q.multiSelect)
                }
                TextField("Outra resposta…", text: Binding(
                    get: { other[index] ?? "" },
                    set: { value in
                        other[index] = value
                        if !value.isEmpty && !q.multiSelect { selected[index] = [] }
                    }))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .card(background: Theme.surfaceLowest, radius: 8)
            }
        }
    }

    private func optionButton(_ option: ChatItem.Question.Option, question: Int, multi: Bool) -> some View {
        let isOn = selected[question]?.contains(option.label) == true
        return OptionRow(label: option.label, detail: option.description,
                         symbol: multi ? (isOn ? "checkmark.square.fill" : "square")
                                       : (isOn ? "largecircle.fill.circle" : "circle"),
                         selected: isOn) {
            var set = selected[question] ?? []
            if multi {
                if isOn { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
                other[question] = ""
            }
            selected[question] = set
        }
    }

    private func answer(for index: Int) -> String? {
        var parts = questions[index].options.map(\.label).filter { selected[index]?.contains($0) == true }
        let custom = (other[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var isComplete: Bool { questions.indices.allSatisfy { answer(for: $0) != nil } }

    private var collectedAnswers: [String: String] {
        var result: [String: String] = [:]
        for index in questions.indices {
            if let answer = answer(for: index) { result[questions[index].question] = answer }
        }
        return result
    }
}

// Renders the markdown subset Claude uses: headings, lists, quotes, rules,
// tables, fenced code blocks and inline styles.
private struct MarkdownText: View {
    enum Block {
        case heading(level: Int, text: String)
        case listItem(indent: Int, marker: String, text: String)
        case quote(String)
        case rule
        case paragraph(String)
        case code(String, language: String)
        case table(header: [String], alignments: [HorizontalAlignment], rows: [[String]])
    }

    let blocks: [Block]
    @Environment(\.projectDirectory) private var directory

    private final class Box { let blocks: [Block]; init(_ blocks: [Block]) { self.blocks = blocks } }
    private static let cache = NSCache<NSString, Box>()

    init(_ source: String) {
        if let cached = Self.cache.object(forKey: source as NSString) {
            blocks = cached.blocks
            return
        }
        blocks = Self.parse(source)
        Self.cache.setObject(Box(blocks), forKey: source as NSString)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var codeLanguage = ""
        var table: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        // A table needs a header row followed by a |---|:---:| separator row;
        // anything else that starts with "|" is kept as plain text.
        func flushTable() {
            defer { table = [] }
            guard !table.isEmpty else { return }
            guard table.count >= 2, let alignments = Self.alignments(table[1]) else {
                paragraph.append(contentsOf: table)
                return
            }
            flushParagraph()
            let header = Self.cells(table[0])
            let rows = table.dropFirst(2).map { row -> [String] in
                let cells = Self.cells(row)
                return (0..<header.count).map { $0 < cells.count ? cells[$0] : "" }
            }
            let columnAlignments = (0..<header.count).map { $0 < alignments.count ? alignments[$0] : .leading }
            blocks.append(.table(header: header, alignments: columnAlignments, rows: rows))
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code == nil && trimmed.hasPrefix("|") {
                table.append(trimmed)
                continue
            }
            flushTable()
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n"), language: codeLanguage))
                    code = nil
                } else {
                    flushParagraph()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
                continue
            }
            if code != nil { code!.append(line); continue }

            let indent = (line.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if trimmed.isEmpty {
                flushParagraph()
            } else if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if trimmed.wholeMatch(of: #/^([-*_])(\s*\1){2,}$/#) != nil {
                flushParagraph()
                blocks.append(.rule)
            } else if let match = trimmed.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                flushParagraph()
                var text = String(match.1)
                var marker = "•"
                if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
                else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
                blocks.append(.listItem(indent: indent, marker: marker, text: text))
            } else if let match = trimmed.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flushParagraph()
                blocks.append(.listItem(indent: indent, marker: "\(match.1).", text: String(match.2)))
            } else if let match = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                flushParagraph()
                blocks.append(.quote(String(match.1)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"), language: codeLanguage)) }
        flushTable()
        flushParagraph()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, Self.isHeading(block) && index > 0 ? 6 : 0)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(attributed(text))
                .scaledFont(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(Theme.brand.opacity(0.8))
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
                Text(attributed(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            Text(attributed(text))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.brand.opacity(0.5)).frame(width: 2)
                }
        case .rule:
            Divider().frame(minWidth: 120)
        case .paragraph(let text):
            Text(attributed(text))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text, let language):
            ScrollView(.horizontal) {
                Text(CodeHighlighter.highlight(text, language: language))
                    .scaledFont(.callout, design: .monospaced)
                    .padding(10)
                    .padding(.trailing, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(background: Theme.codeInset, radius: 8)
            .overlay(alignment: .topTrailing) { CopyButton(text: text).padding(4) }
        case .table(let header, let alignments, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            tableCell(header[column], alignment: alignments[column])
                                .fontWeight(.semibold)
                                .gridColumnAlignment(alignments[column])
                        }
                    }
                    .background(Theme.elevated)
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(header.indices, id: \.self) { column in
                                tableCell(rows[row][column], alignment: alignments[column])
                            }
                        }
                        .background(row % 2 == 1 ? Theme.surfaceLowest : Color.clear)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(1)
            }
        }
    }

    private func tableCell(_ text: String, alignment: HorizontalAlignment) -> some View {
        Text(attributed(text))
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(maxWidth: 320, alignment: Alignment(horizontal: alignment, vertical: .center))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .border(Theme.divider, width: 0.5)
    }

    private static func cells(_ row: String) -> [String] {
        var row = row.replacingOccurrences(of: "\\|", with: "\u{0}")
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{0}", with: "|")
        }
    }

    private static func alignments(_ separator: String) -> [HorizontalAlignment]? {
        let cells = cells(separator)
        guard !cells.isEmpty, cells.allSatisfy({ $0.wholeMatch(of: #/:?-+:?/#) != nil }) else { return nil }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }

    private static func isHeading(_ block: Block) -> Bool {
        if case .heading = block { return true }
        return false
    }

    private func attributed(_ text: String) -> AttributedString {
        Self.attributed(text, linkingFilesIn: directory)
    }

    private final class AttributedBox { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    private static let attributedCache = NSCache<NSString, AttributedBox>()

    /// Inline markdown, with `code spans` that name existing files turned into links.
    static func attributed(_ text: String, linkingFilesIn directory: URL?,
                           codeColor: Color = Theme.textPrimary) -> AttributedString {
        let key = "\(directory?.path ?? "")\u{0}\(codeColor)\u{0}\(text)" as NSString
        if let cached = attributedCache.object(forKey: key) { return cached.value }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].backgroundColor = Theme.surfaceLowest
            result[run.range].foregroundColor = codeColor
            let span = String(result[run.range].characters)
            if let directory, let url = fileURL(for: span, in: directory) {
                result[run.range].link = url
                result[run.range].foregroundColor = Theme.brand
            }
        }
        attributedCache.setObject(AttributedBox(result), forKey: key)
        return result
    }

    private static func fileURL(for span: String, in directory: URL) -> URL? {
        guard span.count < 300, !span.contains(" "), span.contains("/") || span.contains(".") else { return nil }
        // Drop a trailing :line or :line:column.
        let path = span.replacing(#/(:\d+)+$/#, with: "")
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
