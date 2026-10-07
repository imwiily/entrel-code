import Foundation

// Talks to `claude -p` over its stream-json protocol: user messages go in on stdin,
// assistant/tool events and permission requests come back on stdout, one JSON per line.

struct ChatItem: Identifiable {
    enum Kind {
        case user(String)
        case assistant(String)
        case tool(name: String, summary: String, result: String?, isError: Bool)
        case permission(tool: String, summary: String, state: PermissionState)
        case question([Question], answers: [String: String]?)
        case agent(Agent)
        case notice(String)
    }

    struct Agent {
        enum Step {
            case text(String)
            case tool(name: String, summary: String, result: String?, isError: Bool)
        }
        let type: String
        let description: String
        let prompt: String
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
    var kind: Kind
}

final class ChatSession: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var busy = false
    @Published private(set) var running = false
    @Published private(set) var model = ""

    @Published private(set) var directory: URL?
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()

    // Index of the assistant text item currently receiving streamed deltas.
    private var streamingIndex: Int?
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

    func restart() {
        guard let directory else { return }
        stop()
        items = []
        streamingIndex = nil
        toolIndex = [:]
        agentIndex = [:]
        agentStepIndex = [:]
        permissionIndex = [:]
        pendingPermissions = [:]
        buffer = Data()

        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", "exec claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-prompt-tool stdio"]
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
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "initialize"]])
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdin = nil
        running = false
        busy = false
    }

    // MARK: Sending

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, running else { return }
        append(.user(text))
        streamingIndex = nil
        busy = true
        write(["type": "user", "message": ["role": "user", "content": text]])
    }

    func interrupt() {
        guard busy else { return }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func answerPermission(_ itemID: UUID, allow: Bool, always: Bool = false) {
        guard let (requestID, index, request) = takeRequest(for: itemID),
              case .permission(let tool, let summary, _) = items[index].kind else { return }

        var response: [String: Any]
        if allow {
            response = ["behavior": "allow", "updatedInput": request["input"] ?? [:]]
            if always, let suggestions = request["permission_suggestions"] {
                response["updatedPermissions"] = suggestions
            }
        } else {
            response = ["behavior": "deny", "message": "O usuário negou esta ação."]
        }
        items[index].kind = .permission(tool: tool, summary: summary,
                                        state: allow ? (always ? .allowedAlways : .allowed) : .denied)
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
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    private func takeRequest(for itemID: UUID) -> (String, Int, [String: Any])? {
        guard let (requestID, index) = permissionIndex.first(where: { items[$0.value].id == itemID })
                .map({ ($0.key, $0.value) }),
              let request = pendingPermissions.removeValue(forKey: requestID) else { return nil }
        return (requestID, index, request)
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

    private func handle(_ event: [String: Any]) {
        if let parent = event["parent_tool_use_id"] as? String {
            handleSubagent(event, parent: parent)
            return
        }

        switch event["type"] as? String {
        case "system":
            switch event["subtype"] as? String {
            case "init":
                model = event["model"] as? String ?? ""
            case "task_progress":
                if let id = event["tool_use_id"] as? String, let description = event["description"] as? String {
                    updateAgent(id) { $0.progress = description }
                }
            default:
                break
            }
        case "stream_event":
            handleStream(event["event"] as? [String: Any] ?? [:])
        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "Ferramenta"
                // Questions get their own card from the permission request.
                if name == "AskUserQuestion" { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                if Self.isAgentTool(name) {
                    agentIndex[id] = append(.agent(Self.agent(from: input)))
                    streamingIndex = nil
                    continue
                }
                toolIndex[id] = append(.tool(name: name, summary: Self.summary(name: name, input: input), result: nil, isError: false))
                streamingIndex = nil
            }
        case "user":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String, agentIndex[id] != nil {
                    // Prefer the subagent's own report over the hand-back wrapper text.
                    let report = (event["tool_use_result"] as? [String: Any])?["content"]
                    let text = Self.text(of: report).isEmpty ? Self.text(of: block["content"]) : Self.text(of: report)
                    updateAgent(id) {
                        $0.result = text
                        $0.isError = block["is_error"] as? Bool ?? false
                        $0.progress = ""
                    }
                    continue
                }
                guard let id = block["tool_use_id"] as? String, let index = toolIndex[id],
                      case .tool(let name, let summary, _, _) = items[index].kind else { continue }
                items[index].kind = .tool(name: name, summary: summary,
                                          result: Self.text(of: block["content"]),
                                          isError: block["is_error"] as? Bool ?? false)
            }
        case "control_request":
            handleControlRequest(event)
        case "result":
            busy = false
            streamingIndex = nil
            if event["is_error"] as? Bool == true, let message = event["result"] as? String {
                append(.notice(message))
            }
        default:
            break
        }
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
                    agent.steps.append(.tool(name: Self.isAgentTool(name) ? "Subagente" : name,
                                             summary: Self.summary(name: name, input: input),
                                             result: nil, isError: false))
                default:
                    break
                }
            }
        case "user":
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let (owner, step) = agentStepIndex[id],
                      owner == index, case .tool(let name, let summary, _, _) = agent.steps[step] else { continue }
                agent.steps[step] = .tool(name: name, summary: summary,
                                          result: Self.text(of: block["content"]),
                                          isError: block["is_error"] as? Bool ?? false)
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
        case "content_block_start":
            if (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                streamingIndex = append(.assistant(""))
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            if streamingIndex == nil { streamingIndex = append(.assistant("")) }
            if let index = streamingIndex, case .assistant(let current) = items[index].kind {
                items[index].kind = .assistant(current + text)
            }
        case "content_block_stop":
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
        let name = request["display_name"] as? String ?? request["tool_name"] as? String ?? "Ferramenta"
        let input = request["input"] as? [String: Any] ?? [:]
        if request["tool_name"] as? String == "AskUserQuestion" {
            pendingPermissions[requestID] = request
            permissionIndex[requestID] = append(.question(Self.questions(from: input), answers: nil))
            streamingIndex = nil
            return
        }
        let summary = request["description"] as? String ?? Self.summary(name: name, input: input)
        pendingPermissions[requestID] = request
        permissionIndex[requestID] = append(.permission(tool: name, summary: summary, state: .pending))
        streamingIndex = nil
    }

    @discardableResult
    private func append(_ kind: ChatItem.Kind) -> Int {
        items.append(ChatItem(kind: kind))
        return items.count - 1
    }

    // MARK: Helpers

    static func summary(name: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "pattern", "url", "query", "description", "prompt"] {
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
}
