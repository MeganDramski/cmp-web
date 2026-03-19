// src/handlers/postLocation.js
// POST /locations
// Requires: Authorization: Bearer <token>  (driver)
// Body: LocationUpdate object
// Saves to cmp-locations AND updates lastLocation on the load record

const { DynamoDBClient, PutItemCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const LOCATIONS_TABLE = process.env.LOCATIONS_TABLE;
const LOADS_TABLE     = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);

    const body = JSON.parse(event.body || "{}");
    const { loadId, latitude, longitude, speed, heading, timestamp } = body;

    if (!loadId || latitude == null || longitude == null) {
      return respond(400, { error: "loadId, latitude, and longitude are required." });
    }

    const ts = timestamp || new Date().toISOString();
    const locationItem = {
      loadId,
      timestamp:  ts,
      driverId:   body.driverId  || user.email,
      latitude:   Number(latitude),
      longitude:  Number(longitude),
      speed:      Number(speed  || 0),
      heading:    Number(heading || 0),
    };

    // 1. Save individual location record
    await db.send(new PutItemCommand({
      TableName: LOCATIONS_TABLE,
      Item:      marshall(locationItem),
    }));

    // 2. Update lastLocation on the load (for quick reads)
    await db.send(new UpdateItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: loadId }),
      UpdateExpression: "SET lastLocation = :loc",
      ExpressionAttributeValues: marshall({ ":loc": locationItem }),
    }));

    return respond(200, { saved: true, timestamp: ts });
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("postLocation error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
