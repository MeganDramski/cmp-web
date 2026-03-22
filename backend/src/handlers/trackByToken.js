// src/handlers/trackByToken.js
// GET /track/{token}
// PUBLIC endpoint – no auth required
// Returns safe load info + latest location for the customer tracking page

const { DynamoDBClient, QueryCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const LOADS_TABLE     = process.env.LOADS_TABLE;
const LOCATIONS_TABLE = process.env.LOCATIONS_TABLE;

exports.handler = async (event) => {
  try {
    const token = event.pathParameters?.token;
    if (!token) return respond(400, { error: "Tracking token is required." });

    // Look up load by trackingToken (GSI)
    const loadResult = await db.send(new QueryCommand({
      TableName:                LOADS_TABLE,
      IndexName:                "TrackingTokenIndex",
      KeyConditionExpression:   "trackingToken = :t",
      ExpressionAttributeValues: marshall({ ":t": token }),
      Limit:                    1,
    }));

    if (!loadResult.Items || loadResult.Items.length === 0) {
      return respond(404, { error: "No shipment found for this tracking link." });
    }

    const load = unmarshall(loadResult.Items[0]);

    // Fetch latest location + full history for trail.
    // No startedAt filter — return all points so the dispatcher map always
    // has data to show, regardless of when startedAt was recorded.
    // Paginate through DynamoDB pages (each page is capped at 1 MB).
    let lastLocation = null;
    let locationHistory = [];
    try {
      const MAX_POINTS = 500; // enough for a full-day trail
      let lastKey = undefined;
      while (locationHistory.length < MAX_POINTS) {
        const locResult = await db.send(new QueryCommand({
          TableName:                LOCATIONS_TABLE,
          KeyConditionExpression:   "loadId = :lid",
          ExpressionAttributeValues: marshall({ ":lid": load.id }),
          ScanIndexForward:         true,  // ascending = chronological, newest last
          Limit:                    MAX_POINTS,
          ...(lastKey ? { ExclusiveStartKey: lastKey } : {}),
        }));
        if (locResult.Items && locResult.Items.length > 0) {
          locationHistory = locationHistory.concat(locResult.Items.map(unmarshall));
        }
        if (!locResult.LastEvaluatedKey) break;
        lastKey = locResult.LastEvaluatedKey;
      }
      if (locationHistory.length > 0) {
      loadNumber:      load.loadNumber,
      description:     load.description,
      weight:          load.weight,
      pickupAddress:   load.pickupAddress,
      deliveryAddress: load.deliveryAddress,
      pickupDate:      load.pickupDate,
      deliveryDate:    load.deliveryDate,
      status:          load.status,
      trackingToken:   load.trackingToken,
      customerName:    load.customerName,
      customerEmail:   load.customerEmail,
      customerPhone:   load.customerPhone,
      assignedDriverName: load.assignedDriverName || null,
      notes:           load.notes || "",
      lastLocation,
      locationHistory,
    };

    return respond(200, safeLoad);
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("trackByToken error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
