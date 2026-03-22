// src/handlers/stripeWebhook.js
// POST /stripe/webhook
// Handles Stripe events — updates company plan & subscription status.
// NOTE: API Gateway must forward the raw body (no JSON parsing) for
//       signature verification to work. The HttpApi passes the raw body
//       as a base64-encoded string when isBase64Encoded=true.

const stripe = require("stripe")(process.env.STRIPE_SECRET);
const { DynamoDBClient, UpdateItemCommand, QueryCommand } = require("@aws-sdk/client-dynamodb");
const { marshall } = require("@aws-sdk/util-dynamodb");

const db                  = new DynamoDBClient({});
const COMPANIES_TABLE     = process.env.COMPANIES_TABLE;
const WEBHOOK_SECRET      = process.env.STRIPE_WEBHOOK_SECRET;

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

async function updateCompany(tenantId, attrs) {
  if (!tenantId) return;
  const expParts  = [];
  const exprNames = {};
  const exprVals  = {};
  Object.entries(attrs).forEach(([k, v]) => {
    expParts.push(`#${k} = :${k}`);
    exprNames[`#${k}`] = k;
    exprVals[`:${k}`]  = v;
  });
  if (!expParts.length) return;
  await db.send(new UpdateItemCommand({
    TableName: COMPANIES_TABLE,
    Key: marshall({ tenantId }),
    UpdateExpression: "SET " + expParts.join(", "),
    ExpressionAttributeNames:  exprNames,
    ExpressionAttributeValues: marshall(exprVals),
  }));
}

exports.handler = async (event) => {
  // Reconstruct raw body for Stripe signature verification
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body, "base64").toString("utf8")
    : event.body;

  const sig = event.headers?.["stripe-signature"] || event.headers?.["Stripe-Signature"];

  let stripeEvent;
  try {
    stripeEvent = stripe.webhooks.constructEvent(rawBody, sig, WEBHOOK_SECRET);
  } catch (err) {
    console.error("Stripe signature verification failed:", err.message);
    return respond(400, { error: "Webhook signature invalid." });
  }

  const obj  = stripeEvent.data.object;
  const meta = obj.metadata || {};

  try {
    switch (stripeEvent.type) {

      // ── Checkout completed → subscription created ─────────────────────
      case "checkout.session.completed": {
        const tenantId = meta.tenantId || obj.metadata?.tenantId;
        const plan     = meta.plan || "pro";
        if (tenantId) {
          await updateCompany(tenantId, {
            plan,
            status:                "active",
            stripeSubscriptionId:  obj.subscription,
            stripeCustomerId:      obj.customer,
            updatedAt:             new Date().toISOString(),
          });
        }
        break;
      }

      // ── Subscription renewed / updated ────────────────────────────────
      case "customer.subscription.updated": {
        const tenantId = obj.metadata?.tenantId;
        if (tenantId) {
          const isActive = ["active", "trialing"].includes(obj.status);
          await updateCompany(tenantId, {
            plan:      obj.metadata?.plan || "pro",
            status:    isActive ? "active" : "past_due",
            updatedAt: new Date().toISOString(),
          });
        }
        break;
      }

      // ── Subscription cancelled ────────────────────────────────────────
      case "customer.subscription.deleted": {
        const tenantId = obj.metadata?.tenantId;
        if (tenantId) {
          await updateCompany(tenantId, {
            plan:                 "free",
            status:               "cancelled",
            stripeSubscriptionId: null,
            updatedAt:            new Date().toISOString(),
          });
        }
        break;
      }

      // ── Payment failed ────────────────────────────────────────────────
      case "invoice.payment_failed": {
        const customerId = obj.customer;
        // Look up tenant by stripeCustomerId via a scan (infrequent event)
        // In production you'd add a GSI on stripeCustomerId
        const tenantId = obj.subscription_details?.metadata?.tenantId
                      || obj.metadata?.tenantId;
        if (tenantId) {
          await updateCompany(tenantId, {
            status:    "past_due",
            updatedAt: new Date().toISOString(),
          });
        }
        break;
      }

      default:
        // Unhandled event type — acknowledge but do nothing
        break;
    }
  } catch (err) {
    console.error("Error processing Stripe event:", stripeEvent.type, err);
    return respond(500, { error: "Internal error processing webhook." });
  }

  return respond(200, { received: true });
};
