import Foundation

struct ProcessedText {
    var text: String
    var shouldPressEnter: Bool
    var cancelled: Bool
}

enum TextPipeline {
    static func process(_ rawText: String, style: TransformStyle, snippets: [VoiceSnippet]) -> ProcessedText {
        var text = normalizeWhitespace(rawText)
        guard !text.isEmpty else {
            return ProcessedText(text: "", shouldPressEnter: false, cancelled: false)
        }

        if isCancelCommand(text) {
            return ProcessedText(text: "", shouldPressEnter: false, cancelled: true)
        }

        var shouldPressEnter = false
        let enterCommands = ["press enter", "hit enter", "send it"]
        for command in enterCommands where endsWithCommand(text, command) {
            text = removeTrailingCommand(text, command)
            shouldPressEnter = true
            break
        }

        text = expandSnippets(in: text, snippets: snippets)
        let commandStyle = styleFromSpokenCommand(&text)
        text = applySelfCorrections(text)
        text = normalizeSpeechArtifacts(text)
        text = replaceDictationPhrases(text)
        text = normalizePunctuationSpacing(text)
        text = removeConversationalLeadIns(text)
        text = removeFillers(text)
        text = collapseRepeatedClauseRevisions(text)
        text = removeRepeatedWords(text)

        let finalStyle = commandStyle ?? style
        text = apply(style: finalStyle, to: text)
        text = normalizePunctuationSpacing(text)
        text = normalizeWhitespace(text)

        return ProcessedText(text: text, shouldPressEnter: shouldPressEnter, cancelled: false)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCancelCommand(_ text: String) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return ["cancel", "cancel that", "discard that", "stop listening"].contains(lowered)
    }

    private static func endsWithCommand(_ text: String, _ command: String) -> Bool {
        text.lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .hasSuffix(command)
    }

    private static func removeTrailingCommand(_ text: String, _ command: String) -> String {
        guard let range = text.range(of: command, options: [.caseInsensitive, .backwards]) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func expandSnippets(in input: String, snippets: [VoiceSnippet]) -> String {
        var text = input
        for snippet in snippets where !snippet.phrase.isEmpty {
            if text.compare(snippet.phrase, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return snippet.expansion
            }
            text = text.replacingOccurrences(
                of: snippet.phrase,
                with: snippet.expansion,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }
        return text
    }

    private static func styleFromSpokenCommand(_ text: inout String) -> TransformStyle? {
        let commands: [(String, TransformStyle)] = [
            ("make this more professional", .professional),
            ("make this professional", .professional),
            ("rewrite this professionally", .professional),
            ("make this casual", .casual),
            ("turn this into a list", .list),
            ("turn to list", .list),
            ("format as a list", .list),
            ("leave this verbatim", .verbatim)
        ]

        for (command, style) in commands {
            guard text.lowercased().hasPrefix(command) else { continue }
            text = String(text.dropFirst(command.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return style
        }
        return nil
    }

    private static func replaceDictationPhrases(_ input: String) -> String {
        var text = input
        let replacements: [(phrase: String, replacement: String, allowedAtStart: Bool, blockedNextWords: Set<String>)] = [
            ("new paragraph", "\n\n", true, []),
            ("new line", "\n", true, []),
            ("open quote", "\"", true, []),
            ("close quote", "\"", true, []),
            ("quote", "\"", false, ["unquote", "mark", "marks"]),
            ("single quote", "'", true, []),
            ("open parenthesis", "(", true, []),
            ("close parenthesis", ")", true, []),
            ("open bracket", "[", true, []),
            ("close bracket", "]", true, []),
            ("question mark", "?", false, ["icon", "symbol"]),
            ("exclamation mark", "!", false, ["icon", "symbol"]),
            ("exclamation point", "!", false, ["icon", "symbol"]),
            ("comma", ",", false, ["separated", "delimited", "splice", "operator"]),
            ("period", ".", false, ["of", "piece", "pain", "drama", "costume", "tracking"]),
            ("full stop", ".", false, []),
            ("colon", ":", false, ["cancer", "health", "screening"]),
            ("semicolon", ";", false, ["insertion"]),
            ("dash", "-", false, ["board", "cam", "camera", "lane"]),
            ("slash", "/", false, ["command", "commands", "fiction", "mark"]),
            ("at sign", "@", true, [])
        ]

        for replacement in replacements {
            text = replaceCommandPhrase(
                in: text,
                phrase: replacement.phrase,
                with: replacement.replacement,
                allowedAtStart: replacement.allowedAtStart,
                blockedNextWords: replacement.blockedNextWords
            )
        }
        return text
    }

    private static func replaceCommandPhrase(
        in input: String,
        phrase: String,
        with replacement: String,
        allowedAtStart: Bool,
        blockedNextWords: Set<String>
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = #"(?i)(^|\s)"# + escaped + #"(?=\s|$|[.,!?;:])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }

        var output = input
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        for match in matches.reversed() {
            let leadingRange = match.range(at: 1)
            let phraseStart = match.range.location + leadingRange.length
            let phraseLength = match.range.length - leadingRange.length
            let previousText = nsInput.substring(to: phraseStart).trimmingCharacters(in: .whitespacesAndNewlines)
            if !allowedAtStart && previousText.isEmpty {
                continue
            }
            if let next = nextWord(after: phraseStart + phraseLength, in: input),
               blockedNextWords.contains(next.lowercased()) {
                continue
            }

            output = (output as NSString).replacingCharacters(
                in: NSRange(location: phraseStart, length: phraseLength),
                with: replacement
            )
        }
        return output
    }

    private static func nextWord(after location: Int, in input: String) -> String? {
        let nsInput = input as NSString
        guard location < nsInput.length else { return nil }
        let rest = nsInput.substring(from: location)
        guard let regex = try? NSRegularExpression(pattern: #"^\s*([A-Za-z]+)"#),
              let match = regex.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (rest as NSString).substring(with: match.range(at: 1))
    }

    private static func normalizeSpeechArtifacts(_ input: String) -> String {
        input
            .replacingOccurrences(of: #"(?i)(?:\s|^)(?:\[\s*blank[_ ]audio\s*\]|\(\s*blank[_ ]audio\s*\)|<\|nospeech\|>)(?=\s|$)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bet cetera\b"#, with: "etc.", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\betcetera\b"#, with: "etc.", options: .regularExpression)
    }

    private static func normalizePunctuationSpacing(_ input: String) -> String {
        input
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,;:!?])([^\s\d,.;:!?])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\d)\.([^\s\d,.;:!?])"#, with: ". $1", options: .regularExpression)
            .replacingOccurrences(of: #"\betc\s*\."#, with: "etc.", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applySelfCorrections(_ input: String) -> String {
        let strongPatterns = [
            #"(?i)\b(?:take that back|i take that back|scratch that|ignore that|discard that|forget that|remove that)\b[,:;\-\s]*"#,
            #"(?i)\b(?:actually i meant|i didn't mean|i did not mean|what i meant was|no[, ]+i mean|sorry[, ]+i mean|no[, ]+actually)\b[,:;\-\s]*"#
        ]

        for pattern in strongPatterns {
            if let replacement = textAfterLastMatch(pattern: pattern, in: input, requirePriorText: false) {
                return replacement
            }
        }

        if let replacement = textAfterLastMatch(
            pattern: #"(?i)\bi mean\b[,:;\-\s]*"#,
            in: input,
            requirePriorText: true
        ) {
            return replacement
        }

        return input
    }

    private static func textAfterLastMatch(pattern: String, in input: String, requirePriorText: Bool) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard let match = matches.last else { return nil }

        let prefix = nsInput.substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if requirePriorText && prefix.isEmpty {
            return nil
        }

        let start = match.range.location + match.range.length
        guard start < nsInput.length else { return nil }
        let replacement = nsInput.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return replacement.count > 1 ? replacement : nil
    }

    private static func removeFillers(_ input: String) -> String {
        input
            .replacingOccurrences(of: #"\b(um|uh|erm|ah|hmm)\b,?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(kind of|sort of|you know|you know what i mean)\b,?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private static func removeConversationalLeadIns(_ input: String) -> String {
        input
            .replacingOccurrences(
                of: #"(?i)^\s*((also|and)\s+)?(yeah|yep|okay|ok|right|so|well)\b[,\s]*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)^\s*(also|and)\b[,\s]+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeRepeatedWords(_ input: String) -> String {
        var previous = ""
        var output: [String] = []

        for rawWord in input.split(separator: " ") {
            let word = String(rawWord)
            let normalized = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if normalized != previous || normalized.isEmpty {
                output.append(word)
            }
            previous = normalized
        }

        return output.joined(separator: " ")
    }

    private static func collapseRepeatedClauseRevisions(_ input: String) -> String {
        let words = input.split(separator: " ").map(String.init)
        guard words.count >= 8 else { return input }

        for split in 2..<(words.count - 2) {
            guard split <= 24 else { break }
            let left = Array(words[..<split])
            let right = Array(words[split...])
            guard right.count >= 4, left.count <= 24 else { continue }
            guard tokenKey(left[0]) == tokenKey(right[0]),
                  tokenKey(left[1]) == tokenKey(right[1]) else {
                continue
            }

            let comparedRight = Array(right.prefix(left.count))
            guard revisionSimilarity(left: left, right: comparedRight) >= 0.72 else {
                continue
            }

            return right.joined(separator: " ")
        }

        return input
    }

    private static func revisionSimilarity(left: [String], right: [String]) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var rightCounts: [String: Int] = [:]
        for word in right {
            let key = tokenKey(word)
            guard !key.isEmpty else { continue }
            rightCounts[key, default: 0] += 1
        }

        var shared = 0
        for word in left {
            let key = tokenKey(word)
            guard let count = rightCounts[key], count > 0 else { continue }
            shared += 1
            rightCounts[key] = count - 1
        }

        return Double(shared) / Double(max(left.count, right.count))
    }

    private static func tokenKey(_ input: String) -> String {
        input
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func apply(style: TransformStyle, to input: String) -> String {
        switch style {
        case .verbatim:
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        case .clean:
            return finishSentence(capitalizeSentences(input))
        case .professional:
            return makeProfessional(input)
        case .casual:
            return makeCasual(input)
        case .list:
            return makeList(input)
        }
    }

    private static func capitalizeFirst(_ input: String) -> String {
        guard let first = input.first else { return input }
        return first.uppercased() + input.dropFirst()
    }

    private static func capitalizeSentences(_ input: String) -> String {
        var output = ""
        var shouldCapitalize = true

        for character in input {
            if shouldCapitalize, character.isLetter {
                output.append(contentsOf: character.uppercased())
                shouldCapitalize = false
                continue
            }

            output.append(character)
            if ".!?\n".contains(character) {
                shouldCapitalize = true
            } else if !character.isWhitespace {
                shouldCapitalize = false
            }
        }

        return output
    }

    private static func finishSentence(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        if ".!?:;)]}".contains(last) || trimmed.contains("\n") {
            return trimmed
        }
        return trimmed + (looksLikeQuestion(trimmed) ? "?" : ".")
    }

    private static func looksLikeQuestion(_ input: String) -> Bool {
        let firstWord = input
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map(String.init)

        guard let firstWord else { return false }
        let questionWords: Set<String> = [
            "who", "what", "when", "where", "why", "how",
            "is", "are", "am", "was", "were",
            "do", "does", "did",
            "can", "could", "will", "would", "should",
            "has", "have", "had"
        ]
        return questionWords.contains(firstWord)
    }

    private static func makeProfessional(_ input: String) -> String {
        var text = capitalizeSentences(input)
        text = text.replacingOccurrences(of: #"(?i)\bhey\b"#, with: "Hello", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\bthanks\b"#, with: "Thank you", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\bi think\b"#, with: "I think", options: .regularExpression)
        return finishSentence(text)
    }

    private static func makeCasual(_ input: String) -> String {
        var text = capitalizeSentences(input)
        text = text.replacingOccurrences(of: #"(?i)\bhello\b"#, with: "Hey", options: .regularExpression)
        return finishSentence(text)
    }

    private static func makeList(_ input: String) -> String {
        let pieces = input
            .replacingOccurrences(of: " and then ", with: ". ", options: .caseInsensitive)
            .replacingOccurrences(of: " then ", with: ". ", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .map { normalizeWhitespace($0) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return input }
        return pieces.map { "- " + capitalizeFirst($0) }.joined(separator: "\n")
    }
}
