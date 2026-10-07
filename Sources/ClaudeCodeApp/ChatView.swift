import SwiftUI

private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.items.isEmpty { emptyState }
                        ForEach(session.items) { item in
                            ChatRow(item: item, session: session)
                        }
                        if session.busy {
                            ProgressView().controlSize(.small).padding(.leading, 4)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.items.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: lastText) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { inputFocused = true }
    }

    private var lastText: Int {
        guard case .assistant(let text) = session.items.last?.kind else { return 0 }
        return text.count
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 32)).foregroundStyle(accent)
            Text("Como posso ajudar neste projeto?").font(.title3)
            if !session.model.isEmpty {
                Text(session.model).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(session.running ? "Mensagem para o Claude…" : "O Claude Code foi encerrado",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($inputFocused)
                .onSubmit(send)
                .disabled(!session.running)
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
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.running)
                .help("Enviar (Enter)")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .padding(14)
    }

    private func send() {
        guard !session.busy else { return }
        session.send(draft)
        draft = ""
    }
}

private struct ChatRow: View {
    let item: ChatItem
    let session: ChatSession

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.15)))
            }
        case .assistant(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    MarkdownText(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12)))
                    Spacer(minLength: 80)
                }
            }
        case .tool(let name, let summary, let result, let isError):
            ToolRow(name: name, summary: summary, result: result, isError: isError)
        case .permission(let tool, let summary, let state):
            PermissionRow(tool: tool, summary: summary, state: state) { allow, always in
                session.answerPermission(item.id, allow: allow, always: always)
            }
        case .question(let questions, let answers):
            QuestionRow(questions: questions, answers: answers) { answers in
                session.answerQuestion(item.id, answers: answers)
            }
        case .agent(let agent):
            AgentRow(agent: agent)
        case .notice(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ToolRow: View {
    let name: String
    let summary: String
    let result: String?
    let isError: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(name).fontWeight(.semibold)
                    Text(summary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if result != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let result, !result.isEmpty {
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
        if result == nil {
            ProgressView().controlSize(.mini)
        } else if isError {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

private struct PermissionRow: View {
    let tool: String
    let summary: String
    let state: ChatItem.PermissionState
    let answer: (_ allow: Bool, _ always: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Permitir \(tool)?", systemImage: "hand.raised.fill")
                .fontWeight(.semibold)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            switch state {
            case .pending:
                HStack {
                    Button("Permitir") { answer(true, false) }
                        .buttonStyle(.borderedProminent).tint(accent)
                    Button("Sempre permitir") { answer(true, true) }
                    Button("Negar", role: .destructive) { answer(false, false) }
                }
            case .allowed:
                Text("Permitido").font(.caption).foregroundStyle(.secondary)
            case .allowedAlways:
                Text("Sempre permitido").font(.caption).foregroundStyle(.secondary)
            case .denied:
                Text("Negado").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(state == .pending ? 0.6 : 0.2)))
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
                        case .tool(let name, let summary, let result, let isError):
                            ToolRow(name: name, summary: summary, result: result, isError: isError)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
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
