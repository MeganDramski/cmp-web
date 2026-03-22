// src/handlers/getLoads.js
// GET /loads
// Requires: Authorization: Bearer <token>  (dispatcher or driver)
// Returns only loads belonging to the caller's tenant.

const { DynamoDBClient, QueryCommand, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");
const { marshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);

    let loads;

    if (user.tenantId) {
      // Multi-tenant path — query TenantIndex for this company's loads only
      const result = await db.send(new QueryCommand({
        TableName: TABLE,
        IndexName: "TenantIndex",
        KeyConditionExpression: "tenantId = :tid",
        ExpressionAttributeValues: marshall({ ":tid": user.tenantId }),
      }));
      loads = (result.Items || []).map(unmarshall);
    } else {
      // Legacy single-tenant path — full scan (existing CMP data has no tenantId)
      const result = await db.send(new ScanCommand({ TableName: TABLE }));
      loads = (result.Items || []).map(unmarshall);
    }

    // Sort newest first
    loads.sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));

    return respond(200, loads);
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("getLoads error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
