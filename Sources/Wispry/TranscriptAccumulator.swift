import Foundation

struct TranscriptAccumulator {
    private(set) var text = ""

    mutating func reset() {
        text = ""
    }

    mutating func ingest(_ candidate: String, firstSegmentTimestamp: TimeInterval? = nil) -> String {
        let candidate = Self.normalizeWhitespace(candidate)
        guard !candidate.isEmpty else { return text }
        guard !text.isEmpty else {
            text = candidate
            return text
        }

        if firstSegmentTimestamp == nil || (firstSegmentTimestamp ?? 0) < 0.75 {
            text = candidate
            return text
        }

        let existingKey = Self.comparisonKey(text)
        let candidateKey = Self.comparisonKey(candidate)

        if candidateKey == existingKey || existingKey.contains(candidateKey) {
            return text
        }

        if candidateKey.hasPrefix(existingKey) {
            text = candidate
            return text
        }

        let existingTokens = Self.tokens(from: text)
        let candidateTokens = Self.tokens(from: candidate)
        let overlap = Self.overlapCount(existingTokens: existingTokens, candidateTokens: candidateTokens)

        if overlap >= min(2, candidateTokens.count) {
            let wordsToAppend = candidate.split(separator: " ").dropFirst(overlap).map(String.init)
            if !wordsToAppend.isEmpty {
                text = Self.join(text, wordsToAppend.joined(separator: " "))
            }
            return text
        }

        text = Self.join(text, candidate)
        return text
    }

    private static func normalizeWhitespace(_ input: String) -> String {
        input
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ left: String, _ right: String) -> String {
        let trimmedLeft = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeft.isEmpty else { return trimmedRight }
        guard !trimmedRight.isEmpty else { return trimmedLeft }
        return trimmedLeft + " " + trimmedRight
    }

    private static func tokens(from input: String) -> [String] {
        input
            .split(separator: " ")
            .map { tokenKey(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func comparisonKey(_ input: String) -> String {
        tokens(from: input).joined(separator: " ")
    }

    private static func tokenKey(_ input: String) -> String {
        input
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func overlapCount(existingTokens: [String], candidateTokens: [String]) -> Int {
        let maxCount = min(32, existingTokens.count, candidateTokens.count)
        guard maxCount > 0 else { return 0 }

        for count in stride(from: maxCount, through: 1, by: -1) {
            let existingSuffix = existingTokens.suffix(count)
            let candidatePrefix = candidateTokens.prefix(count)
            if Array(existingSuffix) == Array(candidatePrefix) {
                return count
            }
        }

        return 0
    }
}
