const { issueLicense, json, sha256 } = require("./license");

exports.handler = async (event) => {
  if (event.httpMethod !== "POST") {
    return json(405, { error: "POST required." });
  }

  const expectedCode = process.env.SKOOL_CLAIM_CODE;
  if (!expectedCode) {
    return json(503, { error: "Skool license claiming is not configured yet." });
  }

  const body = JSON.parse(event.body || "{}");
  const email = String(body.email || "").trim().toLowerCase();
  const code = String(body.code || "").trim();

  if (!email || !email.includes("@")) {
    return json(400, { error: "Enter the email you use for Skool." });
  }
  if (!code || code !== expectedCode) {
    return json(403, { error: "That Skool claim code is not valid." });
  }

  const license = issueLicense({
    email,
    source: "skool",
    plan: "skool_member",
    licenseId: `skool_${sha256(`${email}:${code}`).slice(0, 24)}`,
  });

  return json(200, {
    license_key: license.key,
    email,
    plan: license.payload.plan,
  });
};
