const assert = require("assert");

const { TransformStyle, processText } = require("../src/text-pipeline");

assert.deepStrictEqual(processText("cancel that"), {
  text: "",
  shouldPressEnter: false,
  cancelled: true
});

assert.deepStrictEqual(processText("hello comma thanks press enter", TransformStyle.professional), {
  text: "Hello, Thank you.",
  shouldPressEnter: true,
  cancelled: false
});

assert.strictEqual(
  processText("new line first item and then second item", TransformStyle.list).text,
  "- First item\n- Second item"
);

assert.strictEqual(
  processText("scratch that send the launch note", TransformStyle.clean).text,
  "Send the launch note."
);

const longIMean = processText(
  "I don't know what changed in the app, but the important thing is that long dictations should keep the whole thought. I mean the user might say I mean naturally in the middle of a sentence while explaining the problem, and that should not delete all of the earlier context from the transcript.",
  TransformStyle.clean
).text;
assert(longIMean.includes("long dictations should keep the whole thought"));
assert(longIMean.split(/[^A-Za-z0-9]+/).filter(Boolean).length > 35);

assert.strictEqual(
  processText("insert signature", TransformStyle.verbatim, [
    { phrase: "insert signature", expansion: "Best,\nLuke" }
  ]).text,
  "Best,\nLuke"
);

console.log("text pipeline tests passed");
