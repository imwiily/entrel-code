import AppKit

// Talks to `claude -p` over its stream-json protocol: user messages go in on stdin,
// assistant/tool events and permission requests come back on stdout, one JSON per line.

struct ChatItem: Identifiable {
    enum Kind {
        case user(UserMessage)
        case assistant(String)
        case tool(Tool)
        case permission(Permission)
        case question([Question], answers: [String: String]?)
        case agent(Agent)
        case choice(Choice)
        case terminalHint(command: String)
        case notice(String)
    }

    /// A native picker for commands that are interactive in the terminal, like /model.
    struct Choice {
        enum Action { case model, command(String) }
        struct Option { let label: String; let detail: String; let value: String }
        let title: String
        let options: [Option]
        let action: Action
        var selected: String?
    }

    struct UserMessage {
        var text: String
        var images: [NSImage] = []
        var files: [String] = []
        /// Sent while Claude was still working; Claude Code folds it into the running turn.
        var queued = false
        /// Handled by the app (e.g. /model), so it isn't part of the saved transcript.
        var local = false
    }

    struct Tool {
        var name: String
        var summary: String
        var filePath: String?
        var detail: ToolDetail?
        var result: String?
        var isError = false
    }

    struct Permission {
        var tool: String
        var summary: String
        var detail: ToolDetail?
        var state: PermissionState = .pending
    }

    struct Agent {
        enum Step {
            case text(String)
            case tool(Tool)
        }
        let type: String
        let description: String
        let prompt: String
        var background = false
        var steps: [Step] = []
        var progress = ""
        var result: String?
        var isError = false
    }

    struct Question {
        struct Option { let label: String; let description: String }
        let question: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
    }

    enum PermissionState { case pending, allowed, allowedAlways, denied }

    let id = UUID()
    /// Bumped on every change so rows can skip re-rendering unchanged items.
    private(set) var revision = 0
    var kind: Kind { didSet { revision &+= 1 } }

    init(kind: Kind) { self.kind = kind }

    /// Plain text used by "find in conversation" and export.
    var searchText: String {
        switch kind {
        case .user(let message): return message.text
        case .assistant(let text): return text
        case .tool(let tool): return "\(tool.name) \(tool.summary) \(tool.result ?? "")"
        case .permission(let permission): return "\(permission.tool) \(permission.summary)"
        case .question(let questions, let answers):
            return questions.map(\.question).joined(separator: " ") + " " + (answers ?? [:]).values.joined(separator: " ")
        case .agent(let agent):
            return "\(agent.description) \(agent.result ?? "")"
        case .choice(let choice): return choice.title
        case .terminalHint(let command): return command
        case .notice(let text): return text
        }
    }
}

struct ModelOption: Identifiable {
    let value: String
    let displayName: String
    let description: String
    var id: String { value }
}

struct SlashCommand: Identifiable {
    let name: String
    let description: String
    let argumentHint: String
    var opensTerminal = false
    var id: String { name }
}

struct TerminalCommand: Identifiable {
    let id = UUID()
    let command: String
}

enum InteractiveCommands {
    /// Commands that only work in the interactive terminal UI. Those marked `whenBare`
    /// also have a usable non-interactive form when given arguments (e.g. /config key=value).
    static let terminal: [(name: String, description: String, whenBare: Bool)] = [
        ("login", "Entrar na sua conta", false),
        ("logout", "Sair da sua conta", false),
        ("status", "Versão, conta, modelo e diagnóstico", false),
        ("config", "Abrir as configurações", true),
        ("permissions", "Gerenciar regras de permissão", false),
        ("memory", "Editar a memória (CLAUDE.md)", false),
        ("mcp", "Gerenciar servidores MCP", true),
        ("hooks", "Gerenciar hooks", false),
        ("theme", "Mudar o tema do terminal", false),
        ("doctor", "Verificar a instalação", false),
        ("ide", "Conectar a uma IDE", false),
        ("plugin", "Gerenciar plugins", false),
        ("add-dir", "Adicionar um diretório de trabalho", false),
        ("export", "Exportar a conversa", false),
        ("release-notes", "Ver as novidades", false),
        ("feedback", "Enviar feedback", false),
        ("bug", "Relatar um problema", false),
        ("privacy-settings", "Configurações de privacidade", false),
        ("statusline", "Configurar a linha de status", false),
        ("terminal-setup", "Configurar o terminal", false),
        ("install-github-app", "Instalar o app do GitHub", false),
        ("upgrade", "Fazer upgrade do plano", false),
        ("vim", "Alternar modo vim", false),
        ("color", "Mudar a cor da sessão", false),
        ("focus", "Modo foco", false),
    ]

    /// Commands the app handles itself.
    static let native: [SlashCommand] = [
        SlashCommand(name: "clear", description: "Começar uma nova conversa", argumentHint: ""),
        SlashCommand(name: "resume", description: "Retomar uma conversa anterior", argumentHint: ""),
        SlashCommand(name: "model", description: "Escolher o modelo", argumentHint: "[modelo]"),
        SlashCommand(name: "effort", description: "Escolher o nível de esforço", argumentHint: "[nível]"),
        SlashCommand(name: "terminal", description: "Abrir o Claude Code interativo aqui", argumentHint: "[comando]"),
    ]
}

struct PermissionModeOption: Identifiable {
    let value: String
    let title: String
    let symbol: String
    var id: String { value }

    static let all = [
        PermissionModeOption(value: "default", title: "Perguntar sempre", symbol: "hand.raised"),
        PermissionModeOption(value: "acceptEdits", title: "Aceitar edições", symbol: "pencil.and.outline"),
        PermissionModeOption(value: "plan", title: "Modo plano", symbol: "list.bullet.clipboard"),
        PermissionModeOption(value: "auto", title: "Automático", symbol: "bolt"),
    ]
}

final class ChatSession: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var busy = false
    @Published private(set) var running = false
    @Published private(set) var activity = ""
    @Published private(set) var directory: URL?
    @Published private(set) var sessionID: String?

    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var commands: [SlashCommand] = []
    @Published private(set) var selectedModel = UserDefaults.standard.string(forKey: "chatModel") ?? "default"
    @Published private(set) var permissionMode = UserDefaults.standard.string(forKey: "permissionMode") ?? "default"
    @Published private(set) var resolvedModel = ""

    @Published private(set) var contextTokens = 0
    @Published private(set) var contextWindow = 200_000
    @Published private(set) var costUSD = 0.0

    /// Set when a command needs the interactive terminal; the UI shows it in a sheet.
    @Published var terminalCommand: TerminalCommand?
    @Published private(set) var loadingHistory = false
    /// Project files offered by @-mention completion, relative to the directory.
    @Published private(set) var projectFiles: [String] = []
    /// Incremented to ask the UI to show the conversation history.
    @Published private(set) var historyRequests = 0
    private var terminalOnlyNames: Set<String> = Set(InteractiveCommands.terminal.map(\.name))
    private var lastSlashCommand: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var initRequestID = ""
    private var replaying = false
    private var replaySubagents: [String: [[String: Any]]] = [:]
    private var generation = 0
    private var pendingSend: String?
    // Streamed text is batched so the UI updates at most ~20 times a second.
    private var pendingDelta = ""
    private var deltaFlushScheduled = false
    private var turnStarted: Date?

    // Index of the assistant text item currently receiving streamed deltas.
    private var streamingIndex: Int?
    // Messages whose text already arrived as stream deltas.
    private var streamedMessages: Set<String> = []
    private var currentMessageID: String?
    private var toolIndex: [String: Int] = [:]
    // Subagent tool_use id -> index of its card. Nested subagents map to the outermost card.
    private var agentIndex: [String: Int] = [:]
    // Tool call made inside a subagent -> (card index, step index).
    private var agentStepIndex: [String: (Int, Int)] = [:]
    private var permissionIndex: [String: Int] = [:]
    private var pendingPermissions: [String: [String: Any]] = [:]

    // MARK: Lifecycle

    func open(_ url: URL) {
        directory = url
        restart()
    }

    /// Starts a fresh conversation.
    func restart() {
        start(resuming: nil)
    }

    /// Reopens a saved conversation: replays its transcript, then continues it.
    func resume(_ id: String) {
        start(resuming: id)
    }

    private func start(resuming resumeID: String?, thenSend text: String? = nil) {
        guard let directory else { return }
        stop()
        generation += 1
        pendingDelta = ""
        items = []
        streamingIndex = nil
        streamedMessages = []
        toolIndex = [:]
        agentIndex = [:]
        agentStepIndex = [:]
        permissionIndex = [:]
        pendingPermissions = [:]
        buffer = Data()
        contextTokens = 0
        costUSD = 0
        sessionID = resumeID
        pendingSend = text
        loadProjectFiles(in: directory)

        guard let resumeID else {
            launch(in: directory, resuming: nil)
            return
        }
        loadingHistory = true
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let history = Transcripts.load(resumeID, in: directory)
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.replay(history)
                self.loadingHistory = false
                self.launch(in: directory, resuming: resumeID)
            }
        }
    }

    private func launch(in directory: URL, resuming resumeID: String?) {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        // Markers from a parent Claude Code session would change how the child behaves.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env[key] = nil }
        env["PATH"] = "\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        var command = "exec claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-prompt-tool stdio"
        command += " --permission-mode \(Self.shellQuote(permissionMode))"
        if selectedModel != "default" { command += " --model \(Self.shellQuote(selectedModel))" }
        if let resumeID { command += " --resume \(Self.shellQuote(resumeID))" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = directory
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            DispatchQueue.main.async { self?.append(.notice(text)) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, proc === self.process else { return }
                self.running = false
                self.busy = false
                self.activity = ""
            }
        }

        do {
            try process.run()
        } catch {
            append(.notice("Não foi possível iniciar o Claude Code: \(error.localizedDescription)"))
            return
        }
        self.process = process
        stdin = inPipe.fileHandleForWriting
        running = true
        initRequestID = UUID().uuidString
        write(["type": "control_request", "request_id": initRequestID, "request": ["subtype": "initialize"]])
        if let text = pendingSend {
            pendingSend = nil
            send(text)
        }
    }

    /// Reconnects after the process exited or settings changed in the terminal,
    /// continuing the current conversation when it has one.
    func reconnect() {
        guard !busy else { return }
        let hasConversation = items.contains { if case .user = $0.kind { return true }; return false }
        if let sessionID, hasConversation { resume(sessionID) } else { restart() }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdin = nil
        running = false
        busy = false
        activity = ""
    }

    // MARK: Sending

    func send(_ text: String, attachments: [Attachment] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty, text.hasPrefix("/"), handleCommand(text) { return }
        guard (!text.isEmpty || !attachments.isEmpty), running else { return }
        lastSlashCommand = text.hasPrefix("/") ? text : nil

        var message = ChatItem.UserMessage(text: text)
        var blocks: [[String: Any]] = []
        var fileLines: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image(let image, let data, let mediaType):
                message.images.append(image)
                blocks.append(["type": "image",
                               "source": ["type": "base64", "media_type": mediaType,
                                          "data": data.base64EncodedString()]])
            case .file(let url):
                message.files.append(url.lastPathComponent)
                fileLines.append("Arquivo anexado: \(url.path)")
            }
        }
        let fullText = ([text] + fileLines).filter { !$0.isEmpty }.joined(separator: "\n")

        message.queued = busy
        append(.user(message))
        streamingIndex = nil
        if !busy {
            busy = true
            activity = "Pensando…"
            turnStarted = Date()
        }

        let content: Any
        if blocks.isEmpty {
            content = fullText
        } else {
            if !fullText.isEmpty { blocks.append(["type": "text", "text": fullText]) }
            content = blocks
        }
        write(["type": "user", "message": ["role": "user", "content": content]])
    }

    /// Handles slash commands that are interactive in the terminal. Returns false
    /// for commands that should go to Claude Code as usual.
    private func handleCommand(_ text: String) -> Bool {
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return false }
        let name = String(first)
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch name {
        case "clear", "new", "reset":
            restart()
            return true
        case "resume", "continue":
            historyRequests += 1
            return true
        case "model":
            if args.isEmpty {
                append(.user(.init(text: text, local: true)))
                append(.choice(.init(
                    title: "Escolha o modelo",
                    options: models.map { .init(label: $0.displayName, detail: $0.description, value: $0.value) },
                    action: .model, selected: nil)))
            } else {
                append(.user(.init(text: text, local: true)))
                setModel(args)
                append(.notice("Modelo alterado para \(args)."))
            }
            return true
        case "effort" where args.isEmpty:
            append(.user(.init(text: text, local: true)))
            let levels = [("low", "Baixo", "Respostas mais rápidas"), ("medium", "Médio", "Equilíbrio"),
                          ("high", "Alto", "Pensa mais"), ("xhigh", "Muito alto", "Para tarefas difíceis"),
                          ("max", "Máximo", "Esforço máximo"), ("auto", "Automático", "O modelo decide")]
            append(.choice(.init(title: "Escolha o nível de esforço",
                                 options: levels.map { .init(label: $0.1, detail: $0.2, value: $0.0) },
                                 action: .command("/effort"), selected: nil)))
            return true
        case "terminal":
            openTerminal(args.isEmpty ? nil : args)
            return true
        default:
            let bareOnly = InteractiveCommands.terminal.first { $0.name == name }?.whenBare ?? false
            guard terminalOnlyNames.contains(name), !(bareOnly && !args.isEmpty) else { return false }
            openTerminal(text)
            return true
        }
    }

    func openTerminal(_ command: String?) {
        if let command { append(.user(.init(text: command, local: true))) }
        terminalCommand = TerminalCommand(command: command ?? "")
    }

    /// Rewrites a sent message: the conversation continues from a copy of the transcript
    /// that ends just before that message, and the new text is sent there. Files changed
    /// after that point are not reverted.
    func edit(_ itemID: UUID, newText: String) {
        guard !busy, let directory, let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        // Only messages that start a turn are prompts in the transcript.
        if case .user(let message) = items[index].kind, message.queued || message.local { return }
        let promptNumber = items[...index].filter {
            if case .user(let message) = $0.kind { return !message.local && !message.queued }
            return false
        }.count
        guard promptNumber > 0 else { return }
        if promptNumber == 1 || sessionID == nil {
            start(resuming: nil, thenSend: newText)
            return
        }
        guard let sessionID, let fork = Transcripts.fork(sessionID, in: directory, beforePrompt: promptNumber) else {
            append(.notice("Não foi possível editar: o histórico desta conversa não foi encontrado."))
            return
        }
        start(resuming: fork, thenSend: newText)
    }

    func exportMarkdown() -> String {
        var lines = ["# Conversa — \(directory?.lastPathComponent ?? "Claude Code")", ""]
        for item in items {
            switch item.kind {
            case .user(let message):
                lines += ["## Você", "", message.text]
                lines += message.files.map { "- 📎 \($0)" }
                if !message.images.isEmpty { lines.append("_(\(message.images.count) imagem(ns))_") }
            case .assistant(let text):
                lines += ["## Claude", "", text]
            case .tool(let tool):
                lines.append("> 🔧 **\(tool.name)** `\(tool.summary)`\(tool.isError ? " — erro" : "")")
            case .agent(let agent):
                lines.append("> 🤖 **Subagente** (\(agent.type)): \(agent.description)")
                if let result = agent.result, !result.isEmpty {
                    lines += [">"] + result.components(separatedBy: "\n").map { "> \($0)" }
                }
            case .permission(let permission):
                lines.append("> ✋ Permissão para \(permission.tool): \(permission.state)")
            case .question(let questions, let answers):
                for question in questions {
                    lines.append("> ❓ \(question.question) → \(answers?[question.question] ?? "sem resposta")")
                }
            case .choice, .terminalHint, .notice:
                continue
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func loadProjectFiles(in directory: URL) {
        let generation = generation
        DispatchQueue.global(qos: .utility).async {
            let files = ProjectFiles.list(in: directory)
            DispatchQueue.main.async {
                if generation == self.generation { self.projectFiles = files }
            }
        }
    }

    func choose(_ itemID: UUID, value: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .choice(var choice) = items[index].kind, choice.selected == nil else { return }
        choice.selected = value
        items[index].kind = .choice(choice)
        switch choice.action {
        case .model:
            setModel(value)
        case .command(let command):
            send("\(command) \(value)")
        }
    }

    func interrupt() {
        guard busy else { return }
        sendControl(["subtype": "interrupt"])
    }

    func setModel(_ value: String) {
        selectedModel = value
        UserDefaults.standard.set(value, forKey: "chatModel")
        if running { sendControl(["subtype": "set_model", "model": value]) }
    }

    func setPermissionMode(_ value: String) {
        permissionMode = value
        UserDefaults.standard.set(value, forKey: "permissionMode")
        if running { sendControl(["subtype": "set_permission_mode", "mode": value]) }
    }

    func answerPermission(_ itemID: UUID, allow: Bool, always: Bool = false) {
        guard let (requestID, index, request) = takeRequest(for: itemID),
              case .permission(var permission) = items[index].kind else { return }

        var response: [String: Any]
        if allow {
            response = ["behavior": "allow", "updatedInput": request["input"] ?? [:]]
            if always, let suggestions = request["permission_suggestions"] {
                response["updatedPermissions"] = suggestions
            }
        } else {
            response = ["behavior": "deny", "message": "O usuário negou esta ação."]
        }
        permission.state = allow ? (always ? .allowedAlways : .allowed) : .denied
        items[index].kind = .permission(permission)
        activity = busy ? "Pensando…" : ""
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    // `answers` maps each question's text to the chosen label(s); nil skips the questions.
    func answerQuestion(_ itemID: UUID, answers: [String: String]?) {
        guard let (requestID, index, request) = takeRequest(for: itemID),
              case .question(let questions, _) = items[index].kind else { return }

        let response: [String: Any]
        if let answers {
            var input = request["input"] as? [String: Any] ?? [:]
            input["answers"] = answers
            response = ["behavior": "allow", "updatedInput": input]
        } else {
            response = ["behavior": "deny", "message": "O usuário preferiu não responder."]
        }
        items[index].kind = .question(questions, answers: answers ?? [:])
        activity = busy ? "Pensando…" : ""
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    private func takeRequest(for itemID: UUID) -> (String, Int, [String: Any])? {
        guard let (requestID, index) = permissionIndex.first(where: { items[$0.value].id == itemID })
                .map({ ($0.key, $0.value) }),
              let request = pendingPermissions.removeValue(forKey: requestID) else { return nil }
        return (requestID, index, request)
    }

    private func sendControl(_ request: [String: Any]) {
        write(["type": "control_request", "request_id": UUID().uuidString, "request": request])
    }

    private func write(_ object: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    // MARK: Receiving

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func replay(_ history: Transcripts.History) {
        guard let events = history.events else {
            append(.notice("Não foi possível ler o histórico desta conversa."))
            return
        }
        replaying = true
        replaySubagents = history.subagents
        defer {
            replaying = false
            replaySubagents = [:]
        }
        for event in events { handle(event) }
        // Background work from an earlier run can't report back any more.
        for (id, _) in agentIndex {
            updateAgent(id) { if $0.result == nil { $0.result = "" } }
        }
        streamingIndex = nil
    }

    #if DEBUG
    /// Feeds protocol events as if replayed from a transcript, for offscreen render tests.
    func injectForTesting(_ events: [[String: Any]], directory: URL? = nil, activity: String? = nil) {
        if let directory { self.directory = directory }
        if let activity {
            running = true
            busy = true
            self.activity = activity
        }
        replaying = true
        for event in events { handle(event) }
        replaying = false
    }
    #endif

    private func handle(_ event: [String: Any]) {
        if let parent = event["parent_tool_use_id"] as? String {
            handleSubagent(event, parent: parent)
            return
        }

        switch event["type"] as? String {
        case "system":
            handleSystem(event)
        case "stream_event":
            handleStream(event["event"] as? [String: Any] ?? [:])
        case "assistant":
            handleAssistant(event)
        case "user":
            handleUser(event)
        case "control_request":
            handleControlRequest(event)
        case "control_response":
            handleControlResponse(event["response"] as? [String: Any] ?? [:])
        case "result":
            handleResult(event)
        case "attachment":
            // Messages sent mid-turn are saved as queued_command attachments.
            if replaying, let attachment = event["attachment"] as? [String: Any],
               attachment["type"] as? String == "queued_command",
               let prompt = attachment["prompt"] as? String, let shown = Self.userText(fromTranscript: prompt) {
                append(.user(.init(text: shown, queued: true)))
            }
        default:
            break
        }
    }

    private func handleSystem(_ event: [String: Any]) {
        switch event["subtype"] as? String {
        case "init":
            resolvedModel = event["model"] as? String ?? resolvedModel
            if let names = event["terminal_slash_commands"] as? [String] {
                terminalOnlyNames.formUnion(names)
            }
            sessionID = event["session_id"] as? String ?? sessionID
            if let mode = event["permissionMode"] as? String, mode != permissionMode {
                permissionMode = mode
            }
        case "status":
            if busy, event["status"] as? String == "requesting" { activity = "Pensando…" }
        case "task_progress":
            if let id = event["tool_use_id"] as? String, let description = event["description"] as? String {
                updateAgent(id) { $0.progress = description }
                if busy { activity = "Subagente: \(description)" }
            }
        case "task_notification":
            guard let id = event["tool_use_id"] as? String else { return }
            let status = event["status"] as? String ?? "completed"
            let summary = event["summary"] as? String ?? event["result"] as? String
            updateAgent(id) {
                if $0.result == nil || $0.background {
                    $0.result = summary ?? (status == "completed" ? "Concluído em segundo plano." : "")
                }
                $0.isError = status != "completed"
                $0.progress = ""
                $0.background = false
            }
        case "local_command":
            // Output of slash commands like /context, as saved in transcripts.
            if let content = event["content"] as? String {
                let text = Self.stripCommandTags(content)
                if !text.isEmpty { append(.assistant(text)) }
            }
        default:
            break
        }
    }

    private func handleAssistant(_ event: [String: Any]) {
        let message = event["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []
        let messageID = message["id"] as? String ?? ""
        let streamed = streamedMessages.contains(messageID)

        if message["model"] as? String != "<synthetic>", let usage = message["usage"] as? [String: Any] {
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
                .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            if tokens > 0 { contextTokens = tokens }
        }

        for block in content {
            switch block["type"] as? String {
            case "text":
                // Live text arrives as stream deltas; replayed and local-command text doesn't.
                guard !streamed, let text = block["text"] as? String else { continue }
                let cleaned = Self.stripCommandTags(text)
                if !replaying, let command = lastSlashCommand, cleaned.contains("isn't available in this environment")
                    || cleaned.contains("in the terminal for details") {
                    if !cleaned.contains("isn't available") { append(.assistant(cleaned)) }
                    append(.terminalHint(command: command))
                    lastSlashCommand = nil
                } else if !cleaned.isEmpty {
                    append(.assistant(cleaned))
                }
                streamingIndex = nil
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "Ferramenta"
                // Questions get their own card from the permission request.
                if name == "AskUserQuestion" { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                streamingIndex = nil
                if Self.isAgentTool(name) {
                    var agent = Self.agent(from: input)
                    agent.background = input["run_in_background"] as? Bool ?? false
                    agentIndex[id] = append(.agent(agent))
                    continue
                }
                if busy { activity = "Executando \(name)…" }
                toolIndex[id] = append(.tool(.init(
                    name: name, summary: Self.summary(name: name, input: input),
                    filePath: input["file_path"] as? String ?? input["notebook_path"] as? String,
                    detail: ToolDetail.make(name: name, input: input, fileMayHaveChanged: replaying))))
            default:
                break
            }
        }
    }

    private func handleUser(_ event: [String: Any]) {
        let message = event["message"] as? [String: Any] ?? [:]
        let toolUseResult = event["tool_use_result"] ?? event["toolUseResult"]

        if let text = message["content"] as? String {
            // Only transcripts replay user text; live input was already added by send().
            if replaying, let shown = Self.userText(fromTranscript: text) {
                append(.user(.init(text: shown)))
            }
            return
        }

        let content = message["content"] as? [[String: Any]] ?? []
        if replaying {
            var userMessage = ChatItem.UserMessage(text: "")
            for block in content {
                if block["type"] as? String == "text", let text = block["text"] as? String,
                   let shown = Self.userText(fromTranscript: text) {
                    userMessage.text += (userMessage.text.isEmpty ? "" : "\n") + shown
                } else if block["type"] as? String == "image",
                          let source = block["source"] as? [String: Any],
                          let base64 = source["data"] as? String,
                          let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                    userMessage.images.append(image)
                }
            }
            if !userMessage.text.isEmpty || !userMessage.images.isEmpty { append(.user(userMessage)) }
        }

        for block in content where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String else { continue }
            let isError = block["is_error"] as? Bool ?? false
            if agentIndex[id] != nil {
                if replaying, let agentID = (toolUseResult as? [String: Any])?["agentId"] as? String {
                    for step in replaySubagents[agentID] ?? [] { handleSubagent(step, parent: id) }
                }
                updateAgent(id) { agent in
                    if agent.background && !self.replaying {
                        agent.progress = "Rodando em segundo plano…"
                        return
                    }
                    // Prefer the subagent's own report over the hand-back wrapper text.
                    let report = Self.text(of: (toolUseResult as? [String: Any])?["content"])
                    agent.result = report.isEmpty ? Self.text(of: block["content"]) : report
                    agent.isError = isError
                    agent.progress = ""
                }
                continue
            }
            guard let index = toolIndex[id], case .tool(var tool) = items[index].kind else { continue }
            tool.result = Self.text(of: block["content"])
            tool.isError = isError
            items[index].kind = .tool(tool)
        }
    }

    private func handleResult(_ event: [String: Any]) {
        flushDelta()
        busy = false
        activity = ""
        streamingIndex = nil
        if let cost = event["total_cost_usd"] as? Double { costUSD = cost }
        if let usage = event["modelUsage"] as? [String: [String: Any]],
           let window = usage.values.compactMap({ $0["contextWindow"] as? Int }).max() {
            contextWindow = window
        }
        if event["is_error"] as? Bool == true, let message = event["result"] as? String {
            append(.notice(message))
        }
        if let started = turnStarted, Date().timeIntervalSince(started) > 10 {
            let last = items.last { if case .assistant = $0.kind { return true }; return false }
            var body = "Pronto."
            if case .assistant(let text) = last?.kind { body = String(text.prefix(140)) }
            Notifier.notify(title: "Claude terminou", body: body)
        }
        turnStarted = nil
    }

    private func handleSubagent(_ event: [String: Any], parent: String) {
        guard let index = agentIndex[parent], case .agent(var agent) = items[index].kind else { return }
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []

        switch event["type"] as? String {
        case "assistant":
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        agent.steps.append(.text(text))
                    }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "Ferramenta"
                    let input = block["input"] as? [String: Any] ?? [:]
                    if Self.isAgentTool(name) { agentIndex[id] = index }
                    agentStepIndex[id] = (index, agent.steps.count)
                    agent.steps.append(.tool(.init(
                        name: Self.isAgentTool(name) ? "Subagente" : name,
                        summary: Self.summary(name: name, input: input),
                        filePath: input["file_path"] as? String ?? input["notebook_path"] as? String,
                        detail: ToolDetail.make(name: name, input: input, fileMayHaveChanged: replaying))))
                default:
                    break
                }
            }
        case "user":
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let (owner, step) = agentStepIndex[id],
                      owner == index, case .tool(var tool) = agent.steps[step] else { continue }
                tool.result = Self.text(of: block["content"])
                tool.isError = block["is_error"] as? Bool ?? false
                agent.steps[step] = .tool(tool)
            }
        default:
            return
        }
        items[index].kind = .agent(agent)
    }

    private func updateAgent(_ id: String, _ change: (inout ChatItem.Agent) -> Void) {
        guard let index = agentIndex[id], case .agent(var agent) = items[index].kind else { return }
        change(&agent)
        items[index].kind = .agent(agent)
    }

    private func handleStream(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            currentMessageID = (event["message"] as? [String: Any])?["id"] as? String
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "text":
                if let currentMessageID { streamedMessages.insert(currentMessageID) }
                streamingIndex = append(.assistant(""))
                activity = "Escrevendo…"
            case "thinking":
                activity = "Pensando…"
            case "tool_use":
                activity = "Preparando \(block["name"] as? String ?? "ferramenta")…"
            default:
                break
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            if streamingIndex == nil {
                if let currentMessageID { streamedMessages.insert(currentMessageID) }
                streamingIndex = append(.assistant(""))
            }
            pendingDelta += text
            if !deltaFlushScheduled {
                deltaFlushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flushDelta() }
            }
        case "content_block_stop":
            flushDelta()
            streamingIndex = nil
        default:
            break
        }
    }

    private func handleControlRequest(_ event: [String: Any]) {
        guard let requestID = event["request_id"] as? String,
              let request = event["request"] as? [String: Any] else { return }
        guard request["subtype"] as? String == "can_use_tool" else {
            write(["type": "control_response",
                   "response": ["subtype": "error", "request_id": requestID, "error": "Não suportado por este app"]])
            return
        }
        let toolName = request["tool_name"] as? String ?? "Ferramenta"
        let name = request["display_name"] as? String ?? toolName
        let input = request["input"] as? [String: Any] ?? [:]
        pendingPermissions[requestID] = request
        streamingIndex = nil

        if toolName == "AskUserQuestion" {
            permissionIndex[requestID] = append(.question(Self.questions(from: input), answers: nil))
            activity = "Aguardando sua resposta"
            Notifier.notify(title: "Claude tem uma pergunta", body: Self.questions(from: input).first?.question ?? "")
            return
        }
        let summary = request["description"] as? String ?? Self.summary(name: name, input: input)
        permissionIndex[requestID] = append(.permission(.init(
            tool: name, summary: summary, detail: ToolDetail.make(name: toolName, input: input))))
        activity = "Aguardando sua aprovação"
        Notifier.notify(title: "Claude precisa da sua aprovação", body: "\(name): \(summary)")
    }

    private func handleControlResponse(_ response: [String: Any]) {
        if response["subtype"] as? String == "error" {
            append(.notice(response["error"] as? String ?? "Erro ao executar o comando."))
            return
        }
        guard response["request_id"] as? String == initRequestID,
              let payload = response["response"] as? [String: Any] else { return }

        models = (payload["models"] as? [[String: Any]] ?? []).map {
            ModelOption(value: $0["value"] as? String ?? "",
                        displayName: $0["displayName"] as? String ?? "",
                        description: $0["description"] as? String ?? "")
        }
        var byName: [String: SlashCommand] = [:]
        for entry in payload["commands"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String, !name.hasPrefix("_") else { continue }
            byName[name] = SlashCommand(name: name, description: entry["description"] as? String ?? "",
                                        argumentHint: entry["argumentHint"] as? String ?? "")
        }
        for command in InteractiveCommands.native { byName[command.name] = command }
        for command in InteractiveCommands.terminal {
            byName[command.name] = SlashCommand(name: command.name, description: command.description,
                                                argumentHint: "", opensTerminal: true)
        }
        commands = byName.values.sorted { $0.name < $1.name }
    }

    private func flushDelta() {
        deltaFlushScheduled = false
        guard !pendingDelta.isEmpty else { return }
        if let index = streamingIndex, index < items.count, case .assistant(let current) = items[index].kind {
            items[index].kind = .assistant(current + pendingDelta)
        }
        pendingDelta = ""
    }

    @discardableResult
    private func append(_ kind: ChatItem.Kind) -> Int {
        flushDelta()
        items.append(ChatItem(kind: kind))
        return items.count - 1
    }

    // MARK: Helpers

    static func summary(name: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "pattern", "url", "query", "description", "prompt", "skill"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            }
        }
        return ""
    }

    static func isAgentTool(_ name: String) -> Bool { name == "Agent" || name == "Task" }

    static func agent(from input: [String: Any]) -> ChatItem.Agent {
        ChatItem.Agent(type: input["subagent_type"] as? String ?? "general-purpose",
                       description: input["description"] as? String ?? "",
                       prompt: input["prompt"] as? String ?? "")
    }

    static func questions(from input: [String: Any]) -> [ChatItem.Question] {
        (input["questions"] as? [[String: Any]] ?? []).map { q in
            ChatItem.Question(
                question: q["question"] as? String ?? "",
                header: q["header"] as? String ?? "",
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    .init(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                },
                multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// What a transcript's user text looked like when typed, or nil for injected context.
    static func userText(fromTranscript text: String) -> String? {
        if let name = text.firstMatch(of: #/<command-name>(.*?)</command-name>/#)?.1 {
            let args = text.firstMatch(of: #/<command-args>(.*?)</command-args>/#)?.1 ?? ""
            let command = name.hasPrefix("/") ? String(name) : "/\(name)"
            return args.isEmpty ? command : "\(command) \(args)"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") || trimmed.hasPrefix("[Request interrupted") { return nil }
        // Drop the "Arquivo anexado:" lines the app adds for attached files.
        let lines = trimmed.components(separatedBy: "\n").filter { !$0.hasPrefix("Arquivo anexado: ") }
        let shown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return shown.isEmpty ? nil : shown
    }

    static func stripCommandTags(_ text: String) -> String {
        text.replacing(#/</?local-command-(stdout|stderr)>/#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
