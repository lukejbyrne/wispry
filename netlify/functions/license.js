const crypto = require("crypto");

function json(statusCode, body) {
  return {
    statusCode,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
    body: JSON.stringify(body),
  };
}

function base64url(buffer) {
  return Buffer.from(buffer)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function privateKey() {
  const encoded = process.env.LICENSE_PRIVATE_KEY_B64;
  if (!encoded) {
    throw new Error("LICENSE_PRIVATE_KEY_B64 is not configured.");
  }
  return crypto.createPrivateKey({
    key: Buffer.from(encoded, "base64"),
    format: "der",
    type: "pkcs8",
  });
}

function issueLicense({ email, source, plan, licenseId }) {
  const normalizedEmail = String(email || "").trim().toLowerCase();
  if (!normalizedEmail || !normalizedEmail.includes("@")) {
    throw new Error("A valid email is required.");
  }

  const payload = {
    v: 1,
    product: "idonttype",
    plan,
    source,
    license_id: licenseId,
    email_sha256: sha256(normalizedEmail),
    issued_at: new Date().toISOString(),
  };
  const payloadBytes = Buffer.from(JSON.stringify(payload), "utf8");
  const signature = crypto.sign(null, payloadBytes, privateKey());

  return {
    key: `IDT1.${base64url(payloadBytes)}.${base64url(signature)}`,
    payload,
  };
}

module.exports = {
  issueLicense,
  json,
  sha256,
};

