import Foundation

struct TextReplacement: Codable, Identifiable, Sendable {
    var id = UUID()
    var find = ""
    var replacement = ""
    var matchCase = false
    var wholeWords = true

    static func apply(_ rules: [Self], to text: String) -> String {
        rules.reduce(text) { text, rule in
            guard !rule.find.isEmpty else { return text }
            let literal = NSRegularExpression.escapedPattern(for: rule.find)
            let pattern = rule.wholeWords ? "(?<![\\p{L}\\p{M}\\p{N}_])\(literal)(?![\\p{L}\\p{M}\\p{N}_])" : literal
            guard let expression = try? NSRegularExpression(
                pattern: pattern, options: rule.matchCase ? [] : [.caseInsensitive]
            ) else { return text }
            return expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
            )
        }
    }
}
