import Darwin
import Foundation

@main
struct TextPipelineSmoke {
    private static var failures: [String] = []

    static func main() {
        testSnippetExpansion()
        testPressEnterCommand()
        testCancelCommand()
        testListTransform()
        testSelfCorrection()
        testCorrectionChain()
        testTakeBackCorrection()
        testFillerAndRepetitionCleanup()
        testConversationalLeadInCleanup()
        testPluralPunctuationWordsStayWords()
        testSpokenPunctuationCommands()
        testSentenceCapitalization()
        testNumericPunctuationSpacing()
        testQuestionPunctuation()
        testCorrectionMarkersDoNotEatNormalNegation()
        testPunctuationWordsCanStayWords()
        testWhisperBlankAudioArtifact()
        testRepeatedFalseStartRevision()
        testTranscriptAccumulatorReplacesFullRevisions()
        testTranscriptAccumulatorKeepsTimedRollingWindows()
        testTranscriptAccumulatorDoesNotDropLongTextOnTimestampRestart()
        testTranscriptAccumulatorReplacesActivePartialRevisions()
        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
        print("TextPipelineSmoke: OK")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures.append(message)
        }
    }

    private static func testSnippetExpansion() {
        let result = TextPipeline.process(
            "insert signature",
            style: .clean,
            snippets: [VoiceSnippet(phrase: "insert signature", expansion: "Best,\nLuke")]
        )
        expect(result.text == "Best,\nLuke", "snippet expansion")
        expect(result.shouldPressEnter == false, "snippet should not press enter")
        expect(result.cancelled == false, "snippet should not cancel")
    }

    private static func testPressEnterCommand() {
        let result = TextPipeline.process(
            "make this more professional hey thanks for reviewing press enter",
            style: .clean,
            snippets: []
        )
        expect(result.text == "Hello Thank you for reviewing.", "press enter professional cleanup")
        expect(result.shouldPressEnter == true, "press enter command")
        expect(result.cancelled == false, "press enter should not cancel")
    }

    private static func testCancelCommand() {
        let result = TextPipeline.process("cancel that", style: .clean, snippets: [])
        expect(result.text.isEmpty, "cancel text empty")
        expect(result.shouldPressEnter == false, "cancel should not press enter")
        expect(result.cancelled == true, "cancel command")
    }

    private static func testListTransform() {
        let result = TextPipeline.process(
            "turn this into a list review the diff then run the build and then ship it",
            style: .clean,
            snippets: []
        )
        expect(result.text == "- Review the diff\n- Run the build\n- Ship it", "list transform")
    }

    private static func testSelfCorrection() {
        let result = TextPipeline.process("it is green no I mean red", style: .clean, snippets: [])
        expect(result.text == "Red.", "i mean correction")
    }

    private static func testCorrectionChain() {
        let result = TextPipeline.process("do this no do that no this actually", style: .clean, snippets: [])
        expect(
            result.text == "Do this no do that no this actually?",
            "plain no/actually should not rewrite meaning, got \(result.text)"
        )
    }

    private static func testTakeBackCorrection() {
        let result = TextPipeline.process("please use the green one take that back use the red one", style: .clean, snippets: [])
        expect(result.text == "Use the red one.", "take back correction")
    }

    private static func testFillerAndRepetitionCleanup() {
        let result = TextPipeline.process("um can you you know review review this", style: .clean, snippets: [])
        expect(result.text == "Can you review this?", "filler and repetition cleanup")
    }

    private static func testConversationalLeadInCleanup() {
        let result = TextPipeline.process("also yeah that's fine", style: .clean, snippets: [])
        expect(result.text == "That's fine.", "conversational lead-in cleanup")
    }

    private static func testPluralPunctuationWordsStayWords() {
        let result = TextPipeline.process("you are not adding commas full stops et cetera", style: .clean, snippets: [])
        expect(result.text == "You are not adding commas full stops etc.", "plural punctuation words stay words")
    }

    private static func testSpokenPunctuationCommands() {
        let result = TextPipeline.process("hello comma please review this full stop thanks", style: .clean, snippets: [])
        expect(result.text == "Hello, please review this. Thanks.", "spoken punctuation commands")
    }

    private static func testSentenceCapitalization() {
        let result = TextPipeline.process("first sentence period second sentence", style: .clean, snippets: [])
        expect(result.text == "First sentence. Second sentence.", "sentence capitalization")
    }

    private static func testNumericPunctuationSpacing() {
        let result = TextPipeline.process("version 3.14 costs 1,000", style: .clean, snippets: [])
        expect(result.text == "Version 3.14 costs 1,000.", "numeric punctuation spacing")
    }

    private static func testQuestionPunctuation() {
        let result = TextPipeline.process("what time is the deploy", style: .clean, snippets: [])
        expect(result.text == "What time is the deploy?", "question punctuation")
    }

    private static func testCorrectionMarkersDoNotEatNormalNegation() {
        let normalNo = TextPipeline.process("there is no reason to wait", style: .clean, snippets: [])
        expect(normalNo.text == "There is no reason to wait.", "normal no should stay")

        let normalActually = TextPipeline.process("we should actually ship today", style: .clean, snippets: [])
        expect(normalActually.text == "We should actually ship today.", "normal actually should stay")

        let explicitCorrection = TextPipeline.process("ship it Friday no, actually ship it Thursday", style: .clean, snippets: [])
        expect(explicitCorrection.text == "Ship it Thursday.", "explicit no actually correction")
    }

    private static func testPunctuationWordsCanStayWords() {
        let csv = TextPipeline.process("comma separated values are common", style: .clean, snippets: [])
        expect(csv.text == "Comma separated values are common.", "comma separated should stay words")

        let history = TextPipeline.process("the period of review is short", style: .clean, snippets: [])
        expect(history.text == "The period of review is short.", "period of should stay words")
    }

    private static func testWhisperBlankAudioArtifact() {
        let result = TextPipeline.process("please review this [BLANK_AUDIO]", style: .clean, snippets: [])
        expect(result.text == "Please review this.", "blank audio artifact should be removed, got \(result.text)")
    }

    private static func testRepeatedFalseStartRevision() {
        let result = TextPipeline.process(
            "there is new day move with you on the there is no day move with you on the website",
            style: .clean,
            snippets: []
        )
        expect(
            result.text == "There is no day move with you on the website.",
            "repeated false-start revision should keep the later version, got \(result.text)"
        )
    }

    private static func testTranscriptAccumulatorReplacesFullRevisions() {
        var accumulator = TranscriptAccumulator()
        _ = accumulator.ingest("I'm just gonna test and see how long this takes", firstSegmentTimestamp: 0)
        _ = accumulator.ingest("So I'm just gonna test and see how long this takes we'll go", firstSegmentTimestamp: 0)
        let result = accumulator.ingest(
            "So I'm just gonna test and see how long this takes we'll go to Gmail",
            firstSegmentTimestamp: 0
        )
        expect(
            result == "So I'm just gonna test and see how long this takes we'll go to Gmail",
            "transcript accumulator should replace full revisions, got \(result)"
        )
    }

    private static func testTranscriptAccumulatorKeepsTimedRollingWindows() {
        var accumulator = TranscriptAccumulator()
        _ = accumulator.ingest("this is the first part of a longer thought", firstSegmentTimestamp: 0)
        _ = accumulator.ingest("longer thought and here is the second part", firstSegmentTimestamp: 12)
        let result = accumulator.ingest("second part and here is the final part", firstSegmentTimestamp: 24)
        expect(
            result == "this is the first part of a longer thought and here is the second part and here is the final part",
            "transcript accumulator should merge timed rolling windows, got \(result)"
        )
    }

    private static func testTranscriptAccumulatorDoesNotDropLongTextOnTimestampRestart() {
        var accumulator = TranscriptAccumulator()
        _ = accumulator.ingest(
            "this is the first paragraph and it has a few ideas about the product and why longer recordings should keep accumulating",
            firstSegmentTimestamp: 0
        )
        let result = accumulator.ingest(
            "the next paragraph starts after Apple speech restarts timestamps",
            firstSegmentTimestamp: 0
        )
        expect(
            result == "this is the first paragraph and it has a few ideas about the product and why longer recordings should keep accumulating the next paragraph starts after Apple speech restarts timestamps",
            "transcript accumulator should not replace long text with restarted timestamp segment, got \(result)"
        )
    }

    private static func testTranscriptAccumulatorReplacesActivePartialRevisions() {
        var accumulator = TranscriptAccumulator()
        _ = accumulator.ingest("as for the do", firstSegmentTimestamp: 18)
        _ = accumulator.ingest("as for the doubling but", firstSegmentTimestamp: 18)
        let result = accumulator.ingest("as for the doubling and the limitation", firstSegmentTimestamp: 18)
        expect(
            result == "as for the doubling and the limitation",
            "transcript accumulator should replace active partial revisions, got \(result)"
        )
    }
}
