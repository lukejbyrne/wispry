# i don't type launch runbook

This is the V1 launch model:

- Website is hosted on Netlify at `https://idonttype.com`.
- Paid users buy a one-time lifetime license through Stripe Checkout.
- Skool members use a private member-only checkout link from Skool. The link opens a $0 Stripe Checkout session before a license is issued.
- The Mac app verifies signed license keys locally, so the app can stay privacy-first and does not need user accounts.
- The downloadable Mac build must be signed with a Developer ID Application certificate and notarized by Apple before public launch.

## Why this model

Normal desktop app companies usually pick one of three launch paths:

- Merchant-of-record licensing, such as Paddle or Lemon Squeezy. Fastest for taxes and license management, but another platform owns more of the customer/payment flow.
- Stripe Checkout plus your own entitlement service. This is what this project uses. It keeps the checkout trusted, lets us issue keys automatically, and avoids building accounts for V1.
- Account login plus subscriptions. Better for complex SaaS teams, but too heavy for a simple private Mac utility launch.

For this app, signed license keys are the right V1 because they are simple, offline-verifiable, privacy-friendly, and easy to hand to both Stripe buyers and Skool members.

## Production environment

Netlify production needs these environment variables:

```text
LICENSE_PRIVATE_KEY_B64
LICENSE_PUBLIC_KEY_B64
SITE_URL=https://idonttype.com
SKOOL_MEMBER_CHECKOUT_TOKEN
STRIPE_PRICE_ID
STRIPE_SECRET_KEY
STRIPE_SKOOL_COUPON_ID
```

`STRIPE_SECRET_KEY` must be a live Stripe secret key and must only be stored as a Netlify secret. Do not commit it.

## Stripe

Current live Stripe objects:

```text
Product: i don't type Founding Lifetime
Product ID: prod_UUJGioC8mpAl6s
Price ID: price_1TVKeJI2Fd5MSakWtEcPzKiI
Amount: $19 USD one-time
```

Checkout route:

```text
https://idonttype.com/checkout
```

The route creates a Stripe Checkout Session, redirects the buyer to Stripe, then returns them to:

```text
https://idonttype.com/success.html?session_id={CHECKOUT_SESSION_ID}
```

The success page verifies the paid Stripe session and issues a signed license key.

## Skool member access

Skool member route:

```text
https://idonttype.com/skool.html
```

Private member checkout route:

```text
https://idonttype.com/member-checkout?token=PRIVATE_TOKEN
```

Put the private member checkout link in a pinned/private Skool post for paid members. Members enter their Skool email, complete a $0 Stripe Checkout session using the server-side Skool coupon, then the success page issues a signed license key. If the link leaks, rotate `SKOOL_MEMBER_CHECKOUT_TOKEN` in Netlify and update the Skool post.

## Apple signing and notarization

Before public launch, the DMG must be signed and notarized.

Required:

- Apple Developer Program membership.
- Developer ID Application certificate installed locally.
- Apple notarization credentials stored locally with `notarytool`.

Build and notarize:

```bash
xcrun notarytool store-credentials idonttype-notary
SIGN_MODE=developer-id NOTARY_PROFILE=idonttype-notary ./build.sh
netlify deploy --prod --dir=site --message "Publish notarized Mac beta"
```

Without this, macOS will show: Apple could not verify the DMG is free of malware.

## Pre-launch checks

Run:

```bash
./test.sh
node -c netlify/functions/license.js
node -c netlify/functions/create-checkout.js
node -c netlify/functions/claim-license.js
node -c netlify/functions/claim-skool-license.js
curl -I https://idonttype.com/checkout
```

Expected:

- Tests pass.
- Function syntax checks pass.
- `/checkout` redirects to Stripe once `STRIPE_SECRET_KEY` is configured.
- `/member-checkout?token=PRIVATE_TOKEN` creates a free Stripe Checkout session for members.
- Downloaded DMG hash matches `site/downloads/IDontType-0.1.0.dmg`.

## Launch checklist

- Add live `STRIPE_SECRET_KEY` to Netlify production.
- Redeploy Netlify production.
- Run one real paid checkout and confirm the success page generates a license.
- Put the private Skool member checkout link in the private paid Skool member area.
- Complete Apple Developer Program enrollment.
- Build with Developer ID signing and notarization.
- Deploy the notarized DMG.
- Test download/install on a clean Mac user account.
- Announce with `https://idonttype.com` and `https://www.skool.com/luke`.
