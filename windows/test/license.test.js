const assert = require("assert");

const { displayPlan, isValid, payloadFor } = require("../src/license");

assert.strictEqual(isValid(""), false);
assert.strictEqual(payloadFor("IDT1.invalid.invalid"), null);
assert.strictEqual(displayPlan(null), "Inactive");
assert.strictEqual(displayPlan({ plan: "founding_lifetime" }), "Founding lifetime");
assert.strictEqual(displayPlan({ plan: "skool_member" }), "Skool member");

console.log("license tests passed");
