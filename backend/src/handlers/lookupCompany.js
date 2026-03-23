// src/handlers/lookupCompany.js
// GET /companies/lookup?name=Acme+Freight
// PUBLIC – no auth required.
// Looks up a company by name (case-insensitive).
// Returns: { exists, tenantId, companyName, hasActiveSubscription }
// Never returns passwords or private data.

const { DynamoDBClient, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");

const db    = new DynamoDBClient({});
const TABLE = process.env.USERS_TABLE;

const ACTIVE_PLANS = new Set(["pro", "active", "trialing"]);

function respond(statusCode, body) {
  return {
    statusCode,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  try {
    const qs   = event.queryStringParameters || {};
    const name = (qs.name || "").trim();

    if (!name || name.length < 2) {
      return respond(400, { error: "name query param is required (min 2 chars)." });
    }

    const nameLower = name.toLowerCase();

    // Scan for dispatcher users whose companyName matches (case-insensitive)
    const result = await db.send(new ScanCommand({
      TableName: TABLE,
      FilterExpression: "#r = :role",
      ExpressionAttributeNames: { "#r": "role" },
      ExpressionAttributeValues: { ":role": { S: "dispatcher" } },
      ProjectionExpression: "tenantId, companyName, #p, #s",
      ExpressionAttributeNames: {
        "#r": "role",
        "#p": "plan",
        "#s": "status",
      },
    }));

    const dispatchers = (result.Items || []).map(unmarshall);

    // Find exact or close match on companyName
    const match = dispatchers.find(d =>
      d.companyName && d.companyName.toLowerCase() === nameLower
    );

    if (!match || !match.tenantId) {
      return respond(200, { exists: false });
    }

    const hasActiveSubscription = ACTIVE_PLANS.has(match.plan || "");

    return respond(200, {
      exists:                  true,
      tenantId:                match.tenantId,
      companyName:             match.companyName,
      hasActiveSubscription,
    });
  } catch (err) {
    console.error("lookupCompany error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
