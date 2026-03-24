// src/handlers/createCheckoutSession.js
// POST /billing/checkout
// Creates a Stripe Checkout session for a plan upgrade.
// Requires: Authorization: Bearer <token>  (dispatcher)
// Body: { plan }  — "pro" | "enterprise"
// Returns: { url }  — redirect the browser to this URL

const stripe = require("stripe")(process.env.STRIPE_SECRET);
const { DynamoDBClient, GetItemCommand, UpdateItemCommand, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db           = new DynamoDBClient({});
// Companies are stored as user records in USERS_TABLE (no separate companies table)
const USERS_TABLE  = process.env.USERS_TABLE;
const AMPLIFY_BASE = (process.env.AMPLIFY_BASE_URL || "").replace(/\/$/, "");

// Map plan names to Stripe Price IDs — replace with your actual Stripe price IDs
const PLAN_PRICES = {
  pro:        process.env.STRIPE_PRICE_PRO        || "price_pro_placeholder",
  enterprise: process.env.STRIPE_PRICE_ENTERPRISE || "price_enterprise_placeholder",
};

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

    // Fetch the admin user record to get/store Stripe customer ID
    // The admin email is stored in the JWT as user.email
    const result = await db.send(new GetItemCommand({
      TableName: USERS_TABLE,
      Key: marshall({ email: user.email }),
    }));
    if (!result.Item) {
      return respond(404, { error: "Account not found." });
    }
    const adminUser = unmarshall(result.Item);

    // Create or reuse Stripe customer
    let customerId = adminUser.stripeCustomerId;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email:    user.email,
        name:     adminUser.companyName || user.companyName,
        metadata: { tenantId: user.tenantId },
      });
      customerId = customer.id;
      // Persist it so future checkouts reuse the same customer
      await db.send(new UpdateItemCommand({
        TableName: USERS_TABLE,
        Key: marshall({ email: user.email }),
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
