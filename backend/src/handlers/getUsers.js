// src/handlers/getUsers.js
// GET /users?role=driver   (or ?role=dispatcher, or no role for all)
// Requires: Authorization: Bearer <token>  (dispatcher only)
// Only returns users belonging to the caller's company (tenantId).

const { DynamoDBClient, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.USERS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    if (user.role !== "dispatcher") {
      return respond(403, { error: "Only dispatchers can list users." });
    }

    const tenantId = user.tenantId;

    // Require tenantId — stale JWT issued before multi-tenant support
    if (!tenantId) {
      return respond(401, { error: "Session expired. Please sign out and sign back in.", code: "STALE_TOKEN" });
    }

    const role = event.queryStringParameters?.role || null;

    // Filter by tenantId to enforce company isolation
    const scanParams = {
      TableName: TABLE,
      FilterExpression: "tenantId = :tid",
      ExpressionAttributeValues: { ":tid": { S: tenantId } },
    };

    const result = await db.send(new ScanCommand(scanParams));
    let users = (result.Items || []).map(unmarshall);

    // Filter by role if requested
    if (role) {
      users = users.filter((u) => u.role === role);
    }

    // Strip password hashes before returning
    users = users.map(({ passwordHash, ...safe }) => safe);

    // Sort by name
    users.sort((a, b) => (a.name || "").localeCompare(b.name || ""));

    return respond(200, users);
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("getUsers error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
