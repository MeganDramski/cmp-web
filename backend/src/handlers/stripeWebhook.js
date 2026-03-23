// src/handlers/stripeWebhook.js
// POST /stripe/webhook
// Handles Stripe events — updates company plan & subscription status in USERS_TABLE.
// NOTE: API Gateway must forward the raw body for signature verification.

const stripe = require("stripe")(process.env.STRIPE_SECRET);
const { DynamoDBClient, UpdateItemCommand, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");

const db             = new DynamoDBClient({});
const USERS_TABLE    = process.env.USERS_TABLE;
const WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET;

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

// Find the admin user for a company by tenantId, then update their record
async function updateCompanyByTenantId(tenantId, attrs) {
  if (!tenantId) return;

  // Find the admin/dispatcher for this tenant
  const scan = await db.send(new ScanCommand({
    TableName: USERS_TABLE,
    FilterExpression: "tenantId = :tid AND #r = :role",
    ExpressionAttributeNames: { "#r": "role" },
    ExpressionAttributeValues: { ":tid": { S: tenantId }, ":role": { S: "dispatcher" } },
  }));

  const users = (scan.Items || []).map(unmarshall);
  if (!users.length) {
    console.warn("stripeWebhook: no dispatcher found for tenantId:", tenantId);
    return;
  }

  // Update all dispatcher users in this tenant (usually just 1 admin)
  for (const user of users) {
    const expParts  = [];
    const exprNames = {};
    const exprVals  = {};
    Object.entries(attrs).forEach(([k, v]) => {
      if (v === null || v === undefined) return; // skip nulls
      expParts.push(`#${k} = :${k}`);
      exprNames[`#${k}`] = k;
      exprVals[`:${k}`]  = v;
    });
    if (!expParts.length) continue;

    await db.send(new UpdateItemCommand({
      TableName: USERS_TABLE,
      Key: marshall({ email: user.email }),
      UpdateExpression: "SET " + expParts.join(", "),
      ExpressionAttributeNames:  exprNames,
      ExpressionAttributeValues: marshall(exprVals),
    }));
  }
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
        const tenantId = meta.tenantId;
        const plan     = meta.plan || "pro";
        if (tenantId) {
          await updateCompanyByTenantId(tenantId, {
            plan,
            stripeSubscriptionId: obj.subscription,
            stripeCustomerId:     obj.customer,
            updatedAt:            new Date().toISOString(),
          });
        }
        break;
      }

      // ── Subscription renewed / updated ────────────────────────────────
      case "customer.subscription.updated": {
        const tenantId = obj.metadata?.tenantId;
        if (tenantId) {
          const isActive = ["active", "trialing"].includes(obj.status);
          await updateCompanyByTenantId(tenantId, {
            plan:      isActive ? (obj.metadata?.plan || "pro") : "inactive",
            updatedAt: new Date().toISOString(),
          });
        }
        break;
      }

      // ── Subscription cancelled ────────────────────────────────────────
      case "customer.subscription.deleted": {
        const tenantId = obj.metadata?.tenantId;
        if (tenantId) {
          await updateCompanyByTenantId(tenantId, {
            plan:      "inactive",
            updatedAt: new Date().toISOString(),
          });
        }
        break;
      }

      // ── Payment failed ────────────────────────────────────────────────
      case "invoice.payment_failed": {
        const tenantId = obj.subscription_details?.metadata?.tenantId
                      || obj.metadata?.tenantId;
        if (tenantId) {
          await updateCompanyByTenantId(tenantId, {
            plan:      "past_due",
            updatedAt: new Date().toISOString(),
          });
        }
        break;
      }

      default:
        break;
    }
  } catch (err) {
    console.error("Error processing Stripe event:", stripeEvent.type, err);
    return respond(500, { error: "Internal error processing webhook." });
  }

  return respond(200, { received: true });
};
