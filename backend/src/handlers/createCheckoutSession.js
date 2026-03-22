// src/handlers/createCheckoutSession.js
// POST /billing/checkout
// Creates a Stripe Checkout session for a plan upgrade.
// Requires: Authorization: Bearer <token>  (dispatcher)
// Body: { plan }  — "pro" | "enterprise"
// Returns: { url }  — redirect the browser to this URL

const stripe = require("stripe")(process.env.STRIPE_SECRET);
const { DynamoDBClient, GetItemCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db              = new DynamoDBClient({});
const COMPANIES_TABLE = process.env.COMPANIES_TABLE;
const AMPLIFY_BASE    = (process.env.AMPLIFY_BASE_URL || "").replace(/\/$/, "");

// Map plan names to Stripe Price IDs — replace with your actual Stripe price IDs
const PLAN_PRICES = {
  pro:        process.env.STRIPE_PRICE_PRO        || "price_pro_placeholder",
  enterprise: process.env.STRIPE_PRICE_ENTERPRISE || "price_enterprise_placeholder",
};

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    if (!user.tenantId) {
      return respond(400, { error: "No company associated with this account." });
    }

    const body = JSON.parse(event.body || "{}");
    const plan = body.plan || "pro";
    const priceId = PLAN_PRICES[plan];
    if (!priceId || priceId.includes("placeholder")) {
      return respond(400, { error: `Unknown plan: ${plan}. Configure STRIPE_PRICE_${plan.toUpperCase()} env var.` });
    }

    // Fetch company to get or create Stripe customer ID
    const result = await db.send(new GetItemCommand({
      TableName: COMPANIES_TABLE,
      Key: marshall({ tenantId: user.tenantId }),
    }));
    if (!result.Item) {
      return respond(404, { error: "Company not found." });
    }
    const company = unmarshall(result.Item);

    // Create or reuse Stripe customer
    let customerId = company.stripeCustomerId;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email:    user.email,
        name:     company.companyName,
        metadata: { tenantId: user.tenantId },
      });
      customerId = customer.id;
      // Persist it so future checkouts reuse the same customer
      await db.send(new UpdateItemCommand({
        TableName: COMPANIES_TABLE,
        Key: marshall({ tenantId: user.tenantId }),
        UpdateExpression: "SET stripeCustomerId = :cid",
        ExpressionAttributeValues: marshall({ ":cid": customerId }),
      }));
    }

    // Create Checkout session
    const session = await stripe.checkout.sessions.create({
      mode:       "subscription",
      customer:   customerId,
      line_items: [{ price: priceId, quantity: 1 }],
      metadata:   { tenantId: user.tenantId, plan },
      success_url: `${AMPLIFY_BASE}/dispatcher.html?billing=success`,
      cancel_url:  `${AMPLIFY_BASE}/dispatcher.html?billing=cancelled`,
    });

    return respond(200, { url: session.url });
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("createCheckoutSession error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
