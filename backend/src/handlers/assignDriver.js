// src/handlers/assignDriver.js
// PATCH /loads/{id}/assign
// Requires: Authorization: Bearer <token>  (dispatcher only)
// Body: { assignedDriverId, assignedDriverName, assignedDriverEmail, assignedDriverPhone }

const { DynamoDBClient, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    if (user.role !== "dispatcher") {
      return respond(403, { error: "Only dispatchers can assign drivers." });
    }

    const loadId = event.pathParameters?.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    const body = JSON.parse(event.body || "{}");
    const {
      assignedDriverId   = null,
      assignedDriverName  = null,
      assignedDriverEmail = null,
      assignedDriverPhone = null,
    } = body;

    // Determine new status
    const newStatus = assignedDriverId ? "Assigned" : "Pending";

    await db.send(new UpdateItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
      UpdateExpression:
        "SET assignedDriverId = :did, assignedDriverName = :dname, " +
        "assignedDriverEmail = :demail, assignedDriverPhone = :dphone, " +
        "#s = :status, updatedAt = :t",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: marshall({
        ":did":    assignedDriverId,
        ":dname":  assignedDriverName,
        ":demail": assignedDriverEmail,
        ":dphone": assignedDriverPhone,
        ":status": newStatus,
        ":t":      new Date().toISOString(),
      }, { removeUndefinedValues: true }),
    }));

    return respond(200, {
      id: loadId,
      assignedDriverId,
      assignedDriverName,
      assignedDriverEmail,
      assignedDriverPhone,
      status: newStatus,
    });
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("assignDriver error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
