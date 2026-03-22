// src/handlers/getUsers.js
// GET /users?role=driver   (or ?role=dispatcher, or no role for all)
// Requires: Authorization: Bearer <token>  (dispatcher only)
// Returns only users belonging to the caller's tenant.

const { DynamoDBClient, QueryCommand, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall, marshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.USERS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    if (user.role !== "dispatcher") {
      return respond(403, { error: "Only dispatchers can list users." });
    }

    const role = event.queryStringParameters?.role || null;

    let users;

    if (user.tenantId) {
      // Multi-tenant — query by TenantIndex GSI
      const result = await db.send(new QueryCommand({
        TableName: TABLE,
        IndexName: "TenantIndex",
        KeyConditionExpression: "tenantId = :tid",
        ExpressionAttributeValues: marshall({ ":tid": user.tenantId }),
      }));
      users = (result.Items || []).map(unmarshall);
    } else {
      // Legacy single-tenant — full scan
      const result = await db.send(new ScanCommand({ TableName: TABLE }));
      users = (result.Items || []).map(unmarshall);
    }

    if (role) {
      users = users.filter((u) => u.role === role);
    }

    // Strip password hashes before returning
    users = users.map(({ passwordHash, ...safe }) => safe);
    users.sort((a, b) => (a.name || "").localeCompare(b.name || ""));

    return respond(200, users);
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("getUsers error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
