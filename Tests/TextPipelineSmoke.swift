import Foundation

@main
struct TextPipelineSmoke {
    static func main() {
        testSnippetExpansion()
        testPressEnterCommand()
        testCancelCommand()
        testListTransform()
        testSelfCorrection()
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

    private static func testQuestionPunctuation() {
        let result = TextPipeline.process("what time is the deploy", style: .clean, snippets: [])
        assert(result.text == "What time is the deploy?")
    }
}
