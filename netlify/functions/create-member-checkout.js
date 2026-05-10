const { json, sha256 } = require("./license");

exports.handler = async (event) => {
  if (event.httpMethod !== "POST") {
    return json(405, { error: "POST required." });
  }

  const secretKey = process.env.STRIPE_SECRET_KEY;
  const priceId = process.env.STRIPE_PRICE_ID;
  const couponId = process.env.STRIPE_SKOOL_COUPON_ID;
  const expectedToken = process.env.SKOOL_MEMBER_CHECKOUT_TOKEN;
  const siteURL = process.env.SITE_URL || "https://idonttype.com";

  if (!secretKey || !priceId || !couponId || !expectedToken) {
    return json(503, { error: "Member checkout is not configured yet." });
  }

  const bodyParams = JSON.parse(event.body || "{}");
  const email = String(bodyParams.email || "").trim().toLowerCase();
  const token = String(bodyParams.token || "").trim();

  if (!email || !email.includes("@")) {
    return json(400, { error: "Enter the email you use for Skool." });
  }
  if (!token || token !== expectedToken) {
    return json(403, { error: "This member checkout link is not valid." });
  }

  const checkoutBody = new URLSearchParams({
    mode: "payment",
    success_url: `${siteURL}/success.html?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${siteURL}/member-checkout.html?token=${encodeURIComponent(token)}`,
    customer_email: email,
    client_reference_id: `skool_${sha256(`${email}:${expectedToken}`).slice(0, 32)}`,
    "line_items[0][price]": priceId,
    "line_items[0][quantity]": "1",
    "discounts[0][coupon]": couponId,
    "metadata[access_source]": "skool_member",
    "metadata[member_token_sha256]": sha256(expectedToken),
    "metadata[email_sha256]": sha256(email),
  });

  const response = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${secretKey}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: checkoutBody,
  });

  if (!response.ok) {
    const text = await response.text();
    return json(502, { error: "Could not create member checkout.", detail: text.slice(0, 500) });
  }

  const session = await response.json();
  return json(200, { url: session.url });
};
