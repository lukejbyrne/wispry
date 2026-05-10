const { json } = require("./license");

exports.handler = async () => {
  const secretKey = process.env.STRIPE_SECRET_KEY;
  const priceId = process.env.STRIPE_PRICE_ID;
  const siteURL = process.env.SITE_URL || "https://idonttype.com";

  if (!secretKey || !priceId) {
    return json(503, {
      error: "Checkout is not enabled yet.",
      detail: "STRIPE_SECRET_KEY and STRIPE_PRICE_ID must be configured in Netlify before paid licenses can be issued automatically.",
    });
  }

  const body = new URLSearchParams({
    mode: "payment",
    success_url: `${siteURL}/success.html?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${siteURL}/#download`,
    "line_items[0][price]": priceId,
    "line_items[0][quantity]": "1",
    allow_promotion_codes: "true",
    billing_address_collection: "auto",
  });

  const response = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${secretKey}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body,
  });

  if (!response.ok) {
    const text = await response.text();
    return json(502, { error: "Could not create Stripe Checkout session.", detail: text.slice(0, 500) });
  }

  const session = await response.json();
  return {
    statusCode: 303,
    headers: {
      location: session.url,
      "cache-control": "no-store",
    },
    body: "",
  };
};
