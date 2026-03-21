// src/handlers/deleteLoad.js
// DELETE /loads/{id}  – permanently delete a load
const { DynamoDBClient, DeleteItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    verifyToken(event);

    const loadId = event.pathParameters && event.pathParameters.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    // Confirm it exists first
    const existing = await db.send(new GetItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
    }));

    if (!existing.Item) {
      return respond(404, { error: "Load not found." });
    }

    await db.send(new DeleteItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
    }));

    return respond(200, { success: true, id: loadId });
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("deleteLoad error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
