const { issueLicense, json } = require("./license");

exports.handler = async (event) => {
  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (!secretKey) {
    return json(503, { error: "License issuing is not configured yet." });
  }

  const params = event.httpMethod === "GET"
    ? event.queryStringParameters || {}
    : JSON.parse(event.body || "{}");
  const sessionId = String(params.session_id || "").trim();

  if (!sessionId.startsWith("cs_")) {
    return json(400, { error: "Missing Stripe Checkout session." });
  }

  const response = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}`, {
    headers: {
      authorization: `Bearer ${secretKey}`,
    },
  });

  if (!response.ok) {
    return json(400, { error: "Could not verify Stripe Checkout session." });
  }

  const session = await response.json();
  if (session.payment_status !== "paid") {
    return json(402, { error: "Payment is not complete yet." });
  }
  if (session.mode !== "payment") {
    return json(400, { error: "Unexpected checkout mode." });
  }
  if (session.currency !== "usd" || Number(session.amount_total || 0) < 1900) {
    return json(400, { error: "Unexpected checkout amount." });
  }

  const email = session.customer_details?.email || session.customer_email;
  const license = issueLicense({
    email,
    source: "stripe",
    plan: "founding_lifetime",
    licenseId: session.id,
  });

  return json(200, {
    license_key: license.key,
    email,
    plan: license.payload.plan,
  });
};

