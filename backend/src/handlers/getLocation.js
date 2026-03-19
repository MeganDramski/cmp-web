// src/handlers/getLocation.js
// GET /loads/{id}/location
// Returns the most-recent location stored for a load
// Requires: Authorization: Bearer <token>

const { DynamoDBClient, QueryCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.LOCATIONS_TABLE;

exports.handler = async (event) => {
  try {
    verifyToken(event);

    const loadId = event.pathParameters?.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    // Query all locations for this load, sorted descending, take the first (latest)
    const result = await db.send(new QueryCommand({
      TableName:                TABLE,
      KeyConditionExpression:   "loadId = :lid",
      ExpressionAttributeValues: marshall({ ":lid": loadId }),
      ScanIndexForward:         false,  // descending by timestamp
      Limit:                    1,
    }));

    if (!result.Items || result.Items.length === 0) {
      return respond(404, { error: "No location data found for this load." });
    }

    return respond(200, unmarshall(result.Items[0]));
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("getLocation error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
