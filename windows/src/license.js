const crypto = require("crypto");

const PUBLIC_KEY_RAW_BASE64 = "DJuLA4imweGqyoFrE1B2GWNwccTMOVnBhKE7DdHSU7w=";
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function base64UrlDecode(value) {
  let base64 = String(value || "")
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  const padding = (4 - (base64.length % 4)) % 4;
  if (padding > 0) {
    base64 += "=".repeat(padding);
  }
  return Buffer.from(base64, "base64");
}

function publicKey() {
  const raw = Buffer.from(PUBLIC_KEY_RAW_BASE64, "base64");
  return crypto.createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
    format: "der",
    type: "spki"
  });
}

function payloadFor(key) {
  const parts = String(key || "").trim().split(".");
  if (parts.length !== 3 || parts[0] !== "IDT1") {
    return null;
  }

  try {
    const payloadData = base64UrlDecode(parts[1]);
    const signatureData = base64UrlDecode(parts[2]);
    const verified = crypto.verify(null, payloadData, publicKey(), signatureData);
    if (!verified) {
      return null;
    }

    const payload = JSON.parse(payloadData.toString("utf8"));
    if (payload.v !== 1 || payload.product !== "idonttype") {
      return null;
    }
    return payload;
  } catch {
    return null;
  }
}

function isValid(key) {
  return payloadFor(key) !== null;
}

function displayPlan(payload) {
  if (!payload) {
    return "Inactive";
  }
  switch (payload.plan) {
    case "founding_lifetime":
      return "Founding lifetime";
    case "skool_member":
      return "Skool member";
    default:
      return String(payload.plan || "Active")
        .replace(/_/g, " ")
        .replace(/\b\w/g, (letter) => letter.toUpperCase());
  }
}

module.exports = {
  displayPlan,
  isValid,
  payloadFor
};
