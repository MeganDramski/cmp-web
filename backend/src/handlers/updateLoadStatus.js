// src/handlers/updateLoadStatus.js
// PATCH /loads/{id}/status
// Requires: Authorization: Bearer <token>
// Body: { status: "In Transit" | "Delivered" | "Pending" | "Assigned" | "Cancelled" }

const { DynamoDBClient, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

const VALID_STATUSES = ["Pending", "Assigned", "In Transit", "Delivered", "Cancelled"];

exports.handler = async (event) => {
  try {
    verifyToken(event);

    const loadId = event.pathParameters?.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    const body = JSON.parse(event.body || "{}");
    if (!VALID_STATUSES.includes(body.status)) {
      return respond(400, { error: `status must be one of: ${VALID_STATUSES.join(", ")}` });
    }

    await db.send(new UpdateItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
      UpdateExpression: "SET #s = :s, updatedAt = :t",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: marshall({
        ":s": body.status,
        ":t": new Date().toISOString(),
      }),
    }));

    return respond(200, { id: loadId, status: body.status });
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("updateLoadStatus error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
