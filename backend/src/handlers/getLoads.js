// src/handlers/getLoads.js
// GET /loads
// Requires: Authorization: Bearer <token>  (dispatcher or driver)
// Only returns loads belonging to the caller's company (tenantId).

const { DynamoDBClient, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    const tenantId = user.tenantId;

    // Require tenantId — if missing the JWT is stale (issued before multi-tenant).
    // The client will receive 401 and re-login to get a fresh token with tenantId.
    if (!tenantId) {
      return respond(401, { error: "Session expired. Please sign out and sign back in.", code: "STALE_TOKEN" });
    }

    // Filter loads to this company only
    const scanParams = {
      TableName: TABLE,
      FilterExpression: "tenantId = :tid",
      ExpressionAttributeValues: { ":tid": { S: tenantId } },
    };

    const result = await db.send(new ScanCommand(scanParams));
    const loads = (result.Items || []).map(unmarshall);

    // Sort newest first
    loads.sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));

    return respond(200, loads);
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("getLoads error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
