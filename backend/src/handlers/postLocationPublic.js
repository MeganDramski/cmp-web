// src/handlers/postLocationPublic.js
// POST /track/{token}/location
// Called from the browser page on the driver's phone — NO auth required.
// Uses the tracking token to identify the load and store the location.

const { DynamoDBClient, QueryCommand, PutItemCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");

const db = new DynamoDBClient({});
const LOADS_TABLE     = process.env.LOADS_TABLE;
const LOCATIONS_TABLE = process.env.LOCATIONS_TABLE;

function respond(statusCode, body) {
  return {
    statusCode,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  try {
    const token = event.pathParameters?.token;
    if (!token) return respond(400, { error: "Token required." });

    const body = JSON.parse(event.body || "{}");
    const { latitude, longitude, speed, heading } = body;

    if (latitude == null || longitude == null) {
      return respond(400, { error: "latitude and longitude are required." });
    }

    // ── Look up load by trackingToken ────────────────────────────────────────
    const loadResult = await db.send(new QueryCommand({
      TableName: LOADS_TABLE,
      IndexName: "TrackingTokenIndex",
      KeyConditionExpression: "trackingToken = :t",
      ExpressionAttributeValues: marshall({ ":t": token }),
      Limit: 1,
    }));

    if (!loadResult.Items || loadResult.Items.length === 0) {
      return respond(404, { error: "No shipment found." });
    }

    const load = unmarshall(loadResult.Items[0]);
    const ts = new Date().toISOString();

    const locationItem = {
      loadId:    load.id,
      timestamp: ts,
      driverId:  load.assignedDriverId || "web-driver",
      latitude:  Number(latitude),
      longitude: Number(longitude),
      speed:     Number(speed || 0),
      heading:   Number(heading || 0),
    };

    // ── Save location record ─────────────────────────────────────────────────
    await db.send(new PutItemCommand({
      TableName: LOCATIONS_TABLE,
      Item: marshall(locationItem),
    }));

    // ── Update lastLocation on the load ──────────────────────────────────────
    await db.send(new UpdateItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: load.id }),
      UpdateExpression: "SET lastLocation = :loc",
      ExpressionAttributeValues: marshall({ ":loc": locationItem }),
    }));

    return respond(200, { saved: true, timestamp: ts });
  } catch (err) {
    console.error("postLocationPublic error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
