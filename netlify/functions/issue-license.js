const { issueLicense, json, sha256 } = require("./license");

exports.handler = async (event) => {
  if (event.httpMethod !== "POST") {
    return json(405, { error: "POST required." });
  }

  const expectedToken = process.env.MANUAL_LICENSE_TOKEN;
  if (!expectedToken) {
    return json(503, { error: "Manual license issuing is not configured." });
  }

  const body = JSON.parse(event.body || "{}");
  const token = String(body.token || "").trim();
  const email = String(body.email || "").trim().toLowerCase();
  const plan = String(body.plan || "founding_lifetime").trim();
  const source = String(body.source || "manual").trim();

  if (token !== expectedToken) {
    return json(403, { error: "Not authorized." });
  }
  if (!email || !email.includes("@")) {
    return json(400, { error: "A valid email is required." });
  }

  const license = issueLicense({
    email,
    source,
    plan,
    licenseId: `manual_${sha256(`${email}:${plan}:${source}`).slice(0, 24)}`,
  });

  return json(200, {
    license_key: license.key,
    email,
    plan: license.payload.plan,
  });
};
