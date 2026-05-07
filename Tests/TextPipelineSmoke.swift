import Foundation

@main
struct TextPipelineSmoke {
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
        print("TextPipelineSmoke: OK")
    }

    private static func testSnippetExpansion() {
        let result = TextPipeline.process(
            "insert signature",
            style: .clean,
            snippets: [VoiceSnippet(phrase: "insert signature", expansion: "Best,\nLuke")]
        )
        assert(result.text == "Best,\nLuke")
        assert(result.shouldPressEnter == false)
        assert(result.cancelled == false)
    }

    private static func testPressEnterCommand() {
        let result = TextPipeline.process(
            "make this more professional hey thanks for reviewing press enter",
            style: .clean,
            snippets: []
        )
        assert(result.text == "Hello Thank you for reviewing.")
        assert(result.shouldPressEnter == true)
        assert(result.cancelled == false)
    }

    private static func testCancelCommand() {
        let result = TextPipeline.process("cancel that", style: .clean, snippets: [])
        assert(result.text.isEmpty)
        assert(result.shouldPressEnter == false)
        assert(result.cancelled == true)
    }

    private static func testListTransform() {
        let result = TextPipeline.process(
            "turn this into a list review the diff then run the build and then ship it",
            style: .clean,
            snippets: []
        )
        assert(result.text == "- Review the diff\n- Run the build\n- Ship it")
    }

    private static func testSelfCorrection() {
        let result = TextPipeline.process("it is green no I mean red", style: .clean, snippets: [])
        assert(result.text == "Red.")
    }

    private static func testCorrectionChain() {
        let result = TextPipeline.process("do this no do that no this actually", style: .clean, snippets: [])
        assert(result.text == "This actually.")
    }

    private static func testTakeBackCorrection() {
        let result = TextPipeline.process("please use the green one take that back use the red one", style: .clean, snippets: [])
        assert(result.text == "Use the red one.")
    }

    private static func testFillerAndRepetitionCleanup() {
        let result = TextPipeline.process("um can you you know review review this", style: .clean, snippets: [])
        assert(result.text == "Can you review this?")
    }

    private static func testConversationalLeadInCleanup() {
        let result = TextPipeline.process("also yeah that's fine", style: .clean, snippets: [])
        assert(result.text == "That's fine.")
    }

    private static func testPluralPunctuationWordsStayWords() {
        let result = TextPipeline.process("you are not adding commas full stops et cetera", style: .clean, snippets: [])
        assert(result.text == "You are not adding commas full stops etc.")
    }

    private static func testSpokenPunctuationCommands() {
        let result = TextPipeline.process("hello comma please review this full stop thanks", style: .clean, snippets: [])
        assert(result.text == "Hello, please review this. Thanks.")
    }

    private static func testSentenceCapitalization() {
        let result = TextPipeline.process("first sentence period second sentence", style: .clean, snippets: [])
        assert(result.text == "First sentence. Second sentence.")
    }

    private static func testNumericPunctuationSpacing() {
        let result = TextPipeline.process("version 3.14 costs 1,000", style: .clean, snippets: [])
        assert(result.text == "Version 3.14 costs 1,000.")
    }

    private static func testQuestionPunctuation() {
        let result = TextPipeline.process("what time is the deploy", style: .clean, snippets: [])
        assert(result.text == "What time is the deploy?")
    }
}
