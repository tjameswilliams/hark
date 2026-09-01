import Foundation

/// Deterministic dictionary replacements — the last line of defense after
/// acoustic vocabulary biasing (Transcriber) and cleanup prompt injection
/// (TranscriptCleaner). Each enabled dictionary entry contributes one rule
/// per alias: alias -> term. "Aisha" -> "Ayesha", every time, no model
/// involved.
///
/// Matching semantics:
///   - case-insensitive on the alias,
///   - whole words only, via Unicode-aware lookarounds
///     `(?<![\p{L}\p{M}\p{N}])alias(?![\p{L}\p{M}\p{N}])` (so "Aisha's"
///     matches — the apostrophe is a boundary — but "Kaisha" does not),
///   - longest alias first across ALL entries (an overlapping shorter alias
///     never clobbers a longer one),
///   - the replacement is the entry's term verbatim — the canonical casing is
///     the whole point.
struct ReplacementEngine: Sendable {
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let alias: String
        /// Regex substitution template built from the term via
        /// `escapedTemplate` (a literal `$` in a term must stay literal).
        let template: String
        let term: String
    }

    private let rules: [Rule]

    init(entries: [DictionaryEntry]) {
        var pairs: [(alias: String, term: String)] = []
        for entry in entries where entry.enabled {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for rawAlias in entry.aliases {
                let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alias.isEmpty,
                      alias.caseInsensitiveCompare(term) != .orderedSame
                else { continue }
                pairs.append((alias, term))
            }
        }
        // Longest-alias-first across all entries; ties break alphabetically
        // for a deterministic order.
        pairs.sort {
            $0.alias.count != $1.alias.count
                ? $0.alias.count > $1.alias.count
                : $0.alias < $1.alias
        }
        let boundary = "\\p{L}\\p{M}\\p{N}"
        rules = pairs.compactMap { pair in
            let escaped = NSRegularExpression.escapedPattern(for: pair.alias)
            let pattern = "(?<![\(boundary)])\(escaped)(?![\(boundary)])"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive])
            else { return nil }
            return Rule(
                regex: regex,
                alias: pair.alias,
                template: NSRegularExpression.escapedTemplate(for: pair.term),
                term: pair.term)
        }
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Applies every rule; returns the corrected text.
    func apply(_ text: String) -> String {
        applyReporting(text).text
    }

    /// Applies every rule and reports which fired (for "dictionary: Aisha ->
    /// Ayesha" logging).
    func applyReporting(_ text: String) -> (text: String, fired: [(alias: String, term: String)]) {
        guard !rules.isEmpty else { return (text, []) }
        var result = text
        var fired: [(alias: String, term: String)] = []
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            guard rule.regex.firstMatch(in: result, range: range) != nil else { continue }
            result = rule.regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: rule.template)
            fired.append((rule.alias, rule.term))
        }
        return (result, fired)
    }
}
