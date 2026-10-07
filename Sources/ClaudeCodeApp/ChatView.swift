import SwiftUI
import UniformTypeIdentifiers

let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var composerHeight: CGFloat = 20
    @State private var focusTrigger = 0
    @State private var selectedSuggestion = 0
    @State private var dismissedSuggestionsFor: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.items.isEmpty { emptyState }
                        ForEach(session.items) { item in
                            ChatRow(item: item, session: session)
                        }
                        if session.busy { activityRow }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.items.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: lastText) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(accent.opacity(0.06))
                    .overlay(Label("Solte para anexar", systemImage: "paperclip").font(.title3))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private var lastText: Int {
        guard case .assistant(let text) = session.items.last?.kind else { return 0 }
        return text.count
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 32)).foregroundStyle(accent)
            Text("Como posso ajudar neste projeto?").font(.title3)
            Text("Arraste arquivos ou cole imagens · digite / para ver os comandos")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var activityRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(session.activity.isEmpty ? "Trabalhando…" : session.activity)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 4)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty { suggestionList }
            if !attachments.isEmpty { attachmentStrip }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Anexar arquivos")
                .padding(.bottom, 9)

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(session.running ? "Mensagem para o Claude…  (Shift+Enter para nova linha)"
                                             : "O Claude Code foi encerrado")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(text: $draft, height: $composerHeight, isEnabled: session.running,
                                     focusTrigger: focusTrigger, onSubmit: send, onKey: handleKey,
                                     onPaste: handlePaste)
                        .frame(height: composerHeight)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))

                if session.busy {
                    Button(action: session.interrupt) {
                        Image(systemName: "stop.fill").frame(width: 20, height: 20)
                    }
                    .help("Interromper (Esc)")
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").frame(width: 20, height: 20)
                    }
                    .disabled(!canSend)
                    .help("Enviar (Enter)")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)

            StatusBar(session: session)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        session.running && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send() {
        guard !session.busy, canSend else { return }
        session.send(draft, attachments: attachments)
        draft = ""
        attachments = []
        dismissedSuggestionsFor = nil
        focusTrigger += 1
    }

    // MARK: Slash commands

    private var suggestions: [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n"),
              dismissedSuggestionsFor != draft else { return [] }
        let query = draft.dropFirst().lowercased()
        let prefix = session.commands.filter { $0.name.lowercased().hasPrefix(query) }
        let contains = session.commands.filter {
            !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query)
        }
        return Array((prefix + contains).prefix(8))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                Button { complete(command) } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)").font(.system(.body, design: .monospaced)).fontWeight(.medium)
                        if !command.argumentHint.isEmpty {
                            Text(command.argumentHint).font(.caption).foregroundStyle(.tertiary)
                        }
                        if command.opensTerminal {
                            Label("terminal", systemImage: "terminal")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .help("Abre numa janela de terminal por cima do chat")
                        }
                        Text(command.description)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(index == clampedSelection ? accent.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var clampedSelection: Int { min(selectedSuggestion, max(suggestions.count - 1, 0)) }

    private func complete(_ command: SlashCommand) {
        draft = "/\(command.name) "
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
            if key == .enter, list[clampedSelection].name == draft.dropFirst() { return false }
            complete(list[clampedSelection])
        case .escape: dismissedSuggestionsFor = draft
        }
        return true
    }

    // MARK: Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        switch attachment.kind {
                        case .image(let image, _, _):
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                        case .file:
                            Image(systemName: "doc").frame(width: 20)
                        }
                        Text(attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 160)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                }
            }
        }
    }

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
        HStack(spacing: 14) {
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
                HStack(spacing: 5) {
                    ProgressView(value: contextFraction)
                        .progressViewStyle(.linear)
                        .frame(width: 50)
                        .tint(contextFraction > 0.8 ? .red : accent)
                    Text("Contexto \(Int((contextFraction * 100).rounded()))% · \(Self.tokens(session.contextTokens)) / \(Self.tokens(session.contextWindow))")
                }
                .help("Quanto da janela de contexto do modelo esta conversa já ocupa")
            }
            if session.costUSD > 0 {
                Text(String(format: "US$ %.2f", session.costUSD))
                    .help("Custo estimado desta sessão, em preço de API")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption)
        .foregroundStyle(.secondary)
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

private struct ChatRow: View {
    let item: ChatItem
    let session: ChatSession

    var body: some View {
        switch item.kind {
        case .user(let message):
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.images.indices, id: \.self) { index in
                                Image(nsImage: message.images[index]).resizable().scaledToFit()
                                    .frame(maxWidth: 220, maxHeight: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    ForEach(message.files, id: \.self) { file in
                        Label(file, systemImage: "doc").font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.15)))
                    }
                }
            }
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
                Image(systemName: "terminal").foregroundStyle(accent)
                Text("\(command) é interativo e precisa do terminal.")
                Spacer()
                Button("Abrir no terminal") { session.terminalCommand = TerminalCommand(command: command) }
                    .buttonStyle(.borderedProminent).tint(accent)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
        case .notice(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ChoiceRow: View {
    let choice: ChatItem.Choice
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(choice.title).fontWeight(.semibold)
            if let selected = choice.selected {
                Label(choice.options.first { $0.value == selected }?.label ?? selected,
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(accent)
            } else {
                ForEach(choice.options, id: \.value) { option in
                    Button { pick(option.value) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                if !option.detail.isEmpty {
                                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(choice.selected == nil ? 0.6 : 0.2)))
    }
}

private struct AssistantBubble: View {
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            MarkdownText(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12)))
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
                .font(.caption)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copiado" : "Copiar")
    }
}

private struct ToolRow: View {
    let tool: ChatItem.Tool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(tool.name).fontWeight(.semibold)
                    Text(tool.summary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if case .diff(_, _, let added, let removed) = tool.detail {
                        DiffStats(added: added, removed: removed)
                    }
                    if tool.result != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let detail = tool.detail { ToolDetailView(detail: detail) }

            if expanded, let result = tool.result, !result.isEmpty {
                ScrollView {
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private var statusIcon: some View {
        if tool.result == nil {
            ProgressView().controlSize(.mini)
        } else if tool.isError {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

private struct DiffStats: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(.green)
            Text("−\(removed)").foregroundStyle(.red)
        }
        .font(.system(.caption, design: .monospaced))
    }
}

private struct ToolDetailView: View {
    let detail: ToolDetail

    var body: some View {
        switch detail {
        case .markdown(let text):
            MarkdownText(text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        case .diff(_, let lines, _, _):
            if lines.isEmpty {
                Text("Nenhuma alteração").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            DiffLineView(line: lines[index])
                        }
                    }
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(marker)
                .frame(width: 18)
                .foregroundStyle(color)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .gap ? .secondary : .primary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context, .gap: return ""
        }
    }

    private var color: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .context, .gap: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.14)
        case .context, .gap: return .clear
        }
    }
}

private struct PermissionRow: View {
    let permission: ChatItem.Permission
    let answer: (_ allow: Bool, _ always: Bool) -> Void

    private var isPlan: Bool { permission.tool == "ExitPlanMode" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(isPlan ? "Aprovar o plano e começar?" : "Permitir \(permission.tool)?",
                      systemImage: isPlan ? "list.bullet.clipboard" : "hand.raised.fill")
                    .fontWeight(.semibold)
                Spacer()
                if case .diff(_, _, let added, let removed) = permission.detail {
                    DiffStats(added: added, removed: removed)
                }
            }
            if !permission.summary.isEmpty && !isPlan {
                Text(permission.summary)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let detail = permission.detail { ToolDetailView(detail: detail) }
            switch permission.state {
            case .pending:
                HStack {
                    Button(isPlan ? "Aprovar plano" : "Permitir") { answer(true, false) }
                        .buttonStyle(.borderedProminent).tint(accent)
                    if !isPlan { Button("Sempre permitir") { answer(true, true) } }
                    Button(isPlan ? "Continuar planejando" : "Negar", role: .destructive) { answer(false, false) }
                }
            case .allowed:
                Text(isPlan ? "Plano aprovado" : "Permitido").font(.caption).foregroundStyle(.secondary)
            case .allowedAlways:
                Text("Sempre permitido").font(.caption).foregroundStyle(.secondary)
            case .denied:
                Text(isPlan ? "Plano recusado" : "Negado").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(permission.state == .pending ? 0.6 : 0.2)))
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
                statusIcon
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(accent)
                Text("Subagente").fontWeight(.semibold)
                Text(agent.type)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.2)))
                if agent.background {
                    Text("segundo plano")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                Text(agent.description).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !agent.steps.isEmpty {
                    Button { showSteps.toggle() } label: {
                        Label("\(agent.steps.count) passos", systemImage: showSteps ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if running && !agent.progress.isEmpty {
                Text(agent.progress).font(.caption).foregroundStyle(.secondary)
            }

            disclosure("Instruções", isOn: $showPrompt) {
                Text(agent.prompt).font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            if showSteps && !agent.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agent.steps.indices, id: \.self) { index in
                        switch agent.steps[index] {
                        case .text(let text):
                            MarkdownText(text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        case .tool(let tool):
                            ToolRow(tool: tool)
                        }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(accent.opacity(0.35)).frame(width: 2)
                }
            }

            if let result = agent.result, !result.isEmpty {
                disclosure("Relatório final", isOn: $showResult) {
                    MarkdownText(result)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder private var statusIcon: some View {
        if running {
            ProgressView().controlSize(.mini)
        } else if agent.isError {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func disclosure<Content: View>(_ title: String, isOn: Binding<Bool>,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isOn.wrappedValue.toggle() } label: {
                Label(title, systemImage: isOn.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isOn.wrappedValue { content() }
        }
    }
}

// MARK: - Conversation history

struct HistoryList: View {
    let directory: URL
    let currentID: String?
    let open: (String) -> Void
    @State private var sessions: [SessionSummary]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversas nesta pasta").font(.headline).padding(12)
            Divider()
            if let sessions {
                if sessions.isEmpty {
                    Text("Nenhuma conversa salva ainda.")
                        .foregroundStyle(.secondary).padding(20)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sessions) { session in
                                Button { open(session.id) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: session.id == currentID ? "bubble.left.fill" : "bubble.left")
                                            .foregroundStyle(session.id == currentID ? accent : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.title).lineLimit(2)
                                            Text(session.date.formatted(.relative(presentation: .named)))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            }
        }
        .frame(width: 380, height: 440, alignment: .top)
        .task {
            let directory = directory
            sessions = await Task.detached { Transcripts.list(for: directory) }.value
        }
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
                HStack {
                    Button("Responder") { submit(collectedAnswers) }
                        .buttonStyle(.borderedProminent).tint(accent)
                        .disabled(!isComplete)
                    Button("Pular") { submit(nil) }
                }
            } else if answers?.isEmpty == true {
                Text("Pergunta ignorada").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(pending ? 0.6 : 0.2)))
    }

    @ViewBuilder private func questionView(_ index: Int) -> some View {
        let q = questions[index]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !q.header.isEmpty {
                    Text(q.header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.2)))
                }
                if q.multiSelect && pending {
                    Text("Escolha uma ou mais").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(q.question).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)

            if let answer = answers?[q.question] {
                Label(answer, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(accent)
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
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func optionButton(_ option: ChatItem.Question.Option, question: Int, multi: Bool) -> some View {
        let isOn = selected[question]?.contains(option.label) == true
        return Button {
            var set = selected[question] ?? []
            if multi {
                if isOn { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = [option.label]
                other[question] = ""
            }
            selected[question] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: multi ? (isOn ? "checkmark.square.fill" : "square")
                                        : (isOn ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isOn ? accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? accent.opacity(0.12) : Color.secondary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case code(String)
        case table(header: [String], alignments: [HorizontalAlignment], rows: [[String]])
    }

    let blocks: [Block]

    init(_ source: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
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
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
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
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushTable()
        flushParagraph()
        self.blocks = blocks
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
            Text(Self.attributed(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
                Text(Self.attributed(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            Text(Self.attributed(text))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                }
        case .rule:
            Divider().frame(minWidth: 120)
        case .paragraph(let text):
            Text(Self.attributed(text))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
                    .padding(.trailing, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
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
                    .background(Color.secondary.opacity(0.12))
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(header.indices, id: \.self) { column in
                                tableCell(rows[row][column], alignment: alignments[column])
                            }
                        }
                        .background(row % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(1)
            }
        }
    }

    private func tableCell(_ text: String, alignment: HorizontalAlignment) -> some View {
        Text(Self.attributed(text))
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(maxWidth: 320, alignment: Alignment(horizontal: alignment, vertical: .center))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .border(Color.secondary.opacity(0.2), width: 0.5)
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

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
