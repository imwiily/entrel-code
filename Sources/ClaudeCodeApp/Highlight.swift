import AppKit
import SwiftUI

/// A small regex highlighter for code blocks: comments, strings, numbers, keywords
/// and type names. It favors being fast and good enough over being exact.
enum CodeHighlighter {
    private static let cache = NSCache<NSString, Box>()
    private final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }

    private static let common: Set<String> = [
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default",
        "true", "false", "null", "nil", "try", "catch", "throw", "throws", "import", "class", "struct",
        "enum", "func", "function", "def", "let", "var", "const", "static", "public", "private",
        "protocol", "interface", "extends", "implements", "new", "this", "self", "super", "in", "is",
        "as", "async", "await", "guard", "where", "init", "extension", "override", "final", "lazy",
        "weak", "some", "any", "type", "typealias", "package", "fn", "pub", "mut", "impl", "trait",
        "use", "mod", "match", "loop", "go", "defer", "chan", "select", "range", "map", "lambda",
        "from", "export", "yield", "with", "pass", "raise", "except", "finally", "elif", "not", "and",
        "or", "None", "True", "False", "then", "fi", "esac", "done", "echo", "local", "readonly",
        "int", "float", "double", "bool", "void", "char", "string", "long", "short", "unsigned",
        "undefined", "typeof", "instanceof", "delete", "of", "get", "set", "inout", "mutating",
        "internal", "fileprivate", "open", "required", "convenience", "deinit", "subscript",
        "associatedtype", "operator", "repeat", "fallthrough", "rethrows", "Self", "super", "select",
    ]
    private static let hashComments: Set<String> = ["python", "py", "sh", "bash", "zsh", "shell", "ruby", "rb",
                                                    "yaml", "yml", "toml", "perl", "r", "dockerfile", "make", "makefile"]

    static func highlight(_ code: String, language: String) -> AttributedString {
        let lang = language.lowercased()
        let key = "\(lang)\u{0}\(code)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }

        var result = AttributedString(code)
        let ns = code as NSString
        let comment = hashComments.contains(lang) ? #"#[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?\*/"#
        let pattern = "(?<comment>\(comment))|(?<string>\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`[^`]*`)"
            + #"|(?<number>\b\d[\d_]*(?:\.\d+)?\b)|(?<word>\b[A-Za-z_][A-Za-z0-9_]*\b)"#
        guard ns.length < 60_000, let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            var color: Color?
            var bold = false
            if match.range(withName: "comment").location != NSNotFound {
                color = Color(nsColor: .secondaryLabelColor)
            } else if match.range(withName: "string").location != NSNotFound {
                color = Color(nsColor: .systemRed)
            } else if match.range(withName: "number").location != NSNotFound {
                color = Color(nsColor: .systemBlue)
            } else if match.range(withName: "word").location != NSNotFound {
                let word = ns.substring(with: match.range)
                if common.contains(word) {
                    color = Color(nsColor: .systemPink); bold = true
                } else if word.first?.isUppercase == true {
                    color = Color(nsColor: .systemTeal)
                }
            }
            guard let color, let range = Range(match.range, in: code),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = color
            if bold { result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized }
        }
        cache.setObject(Box(result), forKey: key)
        return result
    }
}
