import AppKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Tool details (diffs and plans)

struct DiffLine {
    enum Kind { case added, removed, context, gap }
    let kind: Kind
    let text: String
}

enum ToolDetail {
    case diff(file: String, lines: [DiffLine], added: Int, removed: Int)
    case markdown(String)

    /// Builds a preview of what a tool call will change. For Write, the current file is
    /// read so the diff shows real changes; when replaying old transcripts the file may
    /// already contain the new content, so the whole file is shown as added instead.
    static func make(name: String, input: [String: Any], fileMayHaveChanged: Bool = false) -> ToolDetail? {
        let path = input["file_path"] as? String ?? ""
        let shortPath = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        switch name {
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            return diff(file: shortPath, old: old, new: new)
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            let old = edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n")
            let new = edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n")
            return edits.isEmpty ? nil : diff(file: shortPath, old: old, new: new)
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            let current = fileMayHaveChanged ? "" : ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            return diff(file: shortPath, old: current, new: content)
        case "ExitPlanMode":
            guard let plan = input["plan"] as? String, !plan.isEmpty else { return nil }
            return .markdown(plan)
        default:
            return nil
        }
    }

    static func diff(file: String, old: String, new: String) -> ToolDetail {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)

        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var full: [DiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count && removed.contains(i) {
                full.append(.init(kind: .removed, text: oldLines[i])); i += 1
            } else if j < newLines.count && inserted.contains(j) {
                full.append(.init(kind: .added, text: newLines[j])); j += 1
            } else {
                full.append(.init(kind: .context, text: i < oldLines.count ? oldLines[i] : newLines[j]))
                i += 1; j += 1
            }
        }

        // Keep three lines of context around changes and collapse the rest.
        let changed = full.indices.filter { full[$0].kind != .context }
        var keep = Set<Int>()
        for index in changed { keep.formUnion(max(0, index - 3)...min(full.count - 1, index + 3)) }
        var lines: [DiffLine] = []
        var skipped = false
        for (index, line) in full.enumerated() {
            if keep.contains(index) {
                if skipped { lines.append(.init(kind: .gap, text: "…")) }
                skipped = false
                lines.append(line)
            } else {
                skipped = true
            }
        }
        if skipped && !lines.isEmpty { lines.append(.init(kind: .gap, text: "…")) }
        if lines.count > 400 {
            lines = Array(lines.prefix(400)) + [.init(kind: .gap, text: "… (\(lines.count - 400) linhas a mais)")]
        }
        return .diff(file: file, lines: lines, added: inserted.count, removed: removed.count)
    }
}

// MARK: - Attachments

struct Attachment: Identifiable {
    enum Kind {
        case image(NSImage, Data, mediaType: String)
        case file(URL)
    }
    let id = UUID()
    let kind: Kind

    var name: String {
        switch kind {
        case .image: return "Imagem"
        case .file(let url): return url.lastPathComponent
        }
    }

    static func from(url: URL) -> Attachment {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: url), let image = image(from: data) {
            return image
        }
        return Attachment(kind: .file(url))
    }

    /// Downscales and re-encodes so the image stays within the API's size limits.
    static func image(from data: Data) -> Attachment? {
        guard let source = NSImage(data: data), let rep = NSBitmapImageRep(data: data) ?? source.representations
            .compactMap({ $0 as? NSBitmapImageRep }).first ?? source.tiffRepresentation.flatMap(NSBitmapImageRep.init)
        else { return nil }

        let maxSide: CGFloat = 1568
        let width = CGFloat(rep.pixelsWide), height = CGFloat(rep.pixelsHigh)
        let scale = min(1, maxSide / max(width, height, 1))
        let target = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        guard let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width),
                                             pixelsHigh: Int(target.height), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        source.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        var encoded = resized.representation(using: .png, properties: [:])
        var mediaType = "image/png"
        if (encoded?.count ?? 0) > 3_500_000 {
            encoded = resized.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            mediaType = "image/jpeg"
        }
        guard let encoded, let preview = NSImage(data: encoded) else { return nil }
        return Attachment(kind: .image(preview, encoded, mediaType: mediaType))
    }

    /// Attachments from a paste or drop. Returns nil when there is nothing to attach,
    /// so plain text pastes fall through to the text view.
    static func from(pasteboard: NSPasteboard) -> [Attachment]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(from(url:))
        }
        if pasteboard.string(forType: .string) == nil,
           let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = image(from: data) {
            return [image]
        }
        return nil
    }
}

// MARK: - Saved conversations

struct SessionSummary: Identifiable {
    let id: String
    let title: String
    let date: Date
}

enum Transcripts {
    /// Claude Code stores each project's transcripts under ~/.claude/projects, in a
    /// folder named after the working directory with every other character replaced by "-".
    static func folder(for directory: URL) -> URL {
        // realpath, not resolvingSymlinksInPath: the latter strips "/private" from /tmp paths.
        let path = realpath(directory.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? directory.path
        // Matches JavaScript's per-UTF-16-unit replace, so "ã" or an emoji map the same way.
        let name = String(path.utf16.map { unit -> Character in
            let scalar = Unicode.Scalar(unit).map(Character.init)
            return scalar.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" } ?? "-"
        })
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects/\(name)", isDirectory: true)
    }

    static func file(for sessionID: String, in directory: URL) -> URL {
        folder(for: directory).appendingPathComponent("\(sessionID).jsonl")
    }

    static func list(for directory: URL, limit: Int = 50) -> [SessionSummary] {
        let folder = folder(for: directory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return dated.compactMap { url, date in
            guard let title = title(of: url) else { return nil }
            return SessionSummary(id: url.deletingPathExtension().lastPathComponent, title: title, date: date)
        }
    }

    /// A custom or generated title if the transcript has one, else its first prompt.
    /// Returns nil for transcripts without any user prompt.
    private static func title(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var firstPrompt: String?
        var title: String?
        for line in data.split(separator: 0x0A) {
            let isUser = firstPrompt == nil && line.range(of: Data("\"type\":\"user\"".utf8)) != nil
            let isTitle = line.range(of: Data("title\"".utf8)) != nil && line.count < 4000
            guard isUser || isTitle,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if isTitle {
                for key in ["customTitle", "aiTitle", "title"] {
                    if let value = object[key] as? String, !value.isEmpty { title = value }
                }
            }
            if isUser, object["type"] as? String == "user", object["isMeta"] as? Bool != true,
               object["isSidechain"] as? Bool != true {
                let content = (object["message"] as? [String: Any])?["content"]
                let text = (content as? String)
                    ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.first
                if let text, let shown = ChatSession.userText(fromTranscript: text) {
                    firstPrompt = shown
                }
            }
        }
        guard let result = title ?? firstPrompt else { return nil }
        return String(result.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
}

// MARK: - Notifications

enum Notifier {
    // UNUserNotificationCenter throws when the binary isn't inside an app bundle (swift run).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a notification only while the app is in the background.
    static func notify(title: String, body: String) {
        guard available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
