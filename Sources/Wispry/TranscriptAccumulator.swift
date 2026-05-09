import Foundation

struct TranscriptAccumulator {
    private(set) var text = ""
    private var committedText = ""
    private var activeText = ""
    private var activeFirstSegmentTimestamp: TimeInterval?

    mutating func reset() {
        text = ""
        committedText = ""
        activeText = ""
        activeFirstSegmentTimestamp = nil
    }

    mutating func ingest(_ candidate: String, firstSegmentTimestamp: TimeInterval? = nil) -> String {
        let candidate = Self.normalizeWhitespace(candidate)
        guard !candidate.isEmpty else { return text }
        guard !activeText.isEmpty else {
            activeText = candidate
            activeFirstSegmentTimestamp = firstSegmentTimestamp
            rebuildText()
            return text
        }

        let existingKey = Self.comparisonKey(text)
        let candidateKey = Self.comparisonKey(candidate)
        let activeKey = Self.comparisonKey(activeText)

        if candidateKey == existingKey || existingKey.contains(candidateKey) {
            return text
        }

        if candidateKey.hasPrefix(existingKey) {
            committedText = ""
            activeText = candidate
            activeFirstSegmentTimestamp = firstSegmentTimestamp
            rebuildText()
            return text
        }

        let activeTokens = Self.tokens(from: activeText)
        let candidateTokens = Self.tokens(from: candidate)

        if Self.isSameRecognitionWindow(activeFirstSegmentTimestamp, firstSegmentTimestamp),
           Self.shouldReplaceActiveRevision(activeKey: activeKey, activeTokens: activeTokens, candidateKey: candidateKey, candidateTokens: candidateTokens) {
            activeText = candidate
            activeFirstSegmentTimestamp = firstSegmentTimestamp
            rebuildText()
            return text
        }

        let existingTokens = Self.tokens(from: text)
        let overlap = Self.overlapCount(existingTokens: existingTokens, candidateTokens: candidateTokens)

        if overlap >= min(2, candidateTokens.count) {
            committedText = Self.words(from: text).dropLast(overlap).joined(separator: " ")
            activeText = candidate
            activeFirstSegmentTimestamp = firstSegmentTimestamp
            rebuildText()
            return text
        }

        committedText = text
        activeText = candidate
        activeFirstSegmentTimestamp = firstSegmentTimestamp
        rebuildText()
        return text
    }

    private mutating func rebuildText() {
        text = Self.join(committedText, activeText)
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
        words(from: input)
            .map { tokenKey($0) }
            .filter { !$0.isEmpty }
    }

    private static func words(from input: String) -> [String] {
        input
            .split(separator: " ")
            .map(String.init)
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

    private static func shouldReplaceAsFullRevision(existingTokens: [String], candidateTokens: [String]) -> Bool {
        guard !existingTokens.isEmpty, !candidateTokens.isEmpty else { return false }
        guard candidateTokens.count >= Int(Double(existingTokens.count) * 0.72) else {
            return false
        }

        var existingCounts = countsByToken(existingTokens)
        var sharedCount = 0
        for token in candidateTokens {
            if let count = existingCounts[token], count > 0 {
                sharedCount += 1
                existingCounts[token] = count - 1
            }
        }

        let coverage = Double(sharedCount) / Double(max(existingTokens.count, candidateTokens.count))
        return coverage >= 0.52
    }

    private static func isSameRecognitionWindow(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let left), .some(let right)):
            return abs(left - right) < 0.35
        default:
            return false
        }
    }

    private static func shouldReplaceActiveRevision(
        activeKey: String,
        activeTokens: [String],
        candidateKey: String,
        candidateTokens: [String]
    ) -> Bool {
        if candidateKey == activeKey {
            return false
        }
        if activeKey.contains(candidateKey) {
            return false
        }
        if candidateKey.hasPrefix(activeKey) {
            return true
        }
        return shouldReplaceAsFullRevision(existingTokens: activeTokens, candidateTokens: candidateTokens)
    }

    private static func countsByToken(_ tokens: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens {
            counts[token, default: 0] += 1
        }
        return counts
    }
}
