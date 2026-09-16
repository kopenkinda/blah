import Foundation

// Run: swiftc Sources/Blah/TextReplacement.swift Tests/TextReplacementTests.swift -o /tmp/blah-replacement-tests && /tmp/blah-replacement-tests
@main
struct TextReplacementTests {
    static func main() throws {
        let rule = TextReplacement(find: "salute", replacement: "salut")
        assert(TextReplacement.apply([rule], to: "Salute, salute! SALUTE saluted présalute saluté")
               == "salut, salut! salut saluted présalute saluté")
        var sensitive = rule
        sensitive.matchCase = true
        assert(TextReplacement.apply([sensitive], to: "Salute salute") == "Salute salut")
        var partial = rule
        partial.wholeWords = false
        assert(TextReplacement.apply([partial], to: "saluted") == "salutd")

        let literal = TextReplacement(find: "a.b", replacement: "$1\\hello")
        assert(TextReplacement.apply([literal], to: "a.b axb") == "$1\\hello axb")
        let phrase = TextReplacement(find: "hey there", replacement: "hello")
        assert(TextReplacement.apply([phrase], to: "Hey there!") == "hello!")
        assert(TextReplacement.apply([TextReplacement(), rule], to: "salute") == "salut")
        assert(TextReplacement.apply([TextReplacement(find: "salute")], to: "salute!") == "!")
        let next = TextReplacement(find: "salut", replacement: "bonjour")
        assert(TextReplacement.apply([rule, next], to: "salute") == "bonjour")
        assert(TextReplacement.apply([], to: "Salute") == "Salute")

        let restored = try JSONDecoder().decode([TextReplacement].self, from: JSONEncoder().encode([sensitive, partial]))
        assert(restored[0].id == sensitive.id && restored[0].matchCase && !restored[1].wholeWords)
        assert(TextReplacement.apply(restored, to: "salute") == "salut")
        print("Replacement checks passed")
    }
}
