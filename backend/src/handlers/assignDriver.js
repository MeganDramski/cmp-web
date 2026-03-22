// src/handlers/assignDriver.js
// PATCH /loads/{id}/assign
const { DynamoDBClient, UpdateItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, un = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    if (user.role !== "dispatcher") {
      return respond(403, { error: "Only dispatchers can assign drivers." });
    }

    const loadId = event.pathParameters?.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    // Tenant isolation check
    if (user.tenantId) {
      const existing = await db.send(new GetItemCommand({
        TableName: TABLE,
        Key: marshall({ id: loadId }),
      }));
      if (!existing.Item) return respond(404, { error: "Load not found." });
      const existingLoad = unmarshall(existing.Item);
      if (existingLoad.tenantId && existingLoad.tenantId !== user.tenantId) {
        return respond(403, { error: "Access denied." });
      }
    }

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
