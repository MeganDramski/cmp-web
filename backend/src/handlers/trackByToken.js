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

    // Fetch location history.
    // If ?live=1 (dispatcher live map poll) fetch only the last 100 points — fast.
    // Otherwise fetch up to 500 for the full customer tracking view.
    const isLivePoll = event.queryStringParameters?.live === '1';
    const MAX_POINTS = isLivePoll ? 100 : 500;

    let lastLocation = load.lastLocation || null;
    let locationHistory = [];
    try {
      let lastKey = undefined;
      while (locationHistory.length < MAX_POINTS) {
        const locResult = await db.send(new QueryCommand({
          TableName:                LOCATIONS_TABLE,
          KeyConditionExpression:   "loadId = :lid",
          ExpressionAttributeValues: marshall({ ":lid": load.id }),
          ScanIndexForward:         !isLivePoll,  // live poll: descending (newest first), full: ascending
          Limit:                    MAX_POINTS,
          ...(lastKey ? { ExclusiveStartKey: lastKey } : {}),
        }));
        if (locResult.Items && locResult.Items.length > 0) {
          locationHistory = locationHistory.concat(locResult.Items.map(unmarshall));
        }
        // For live polls stop after the first page — we only want the latest 100
        if (isLivePoll || !locResult.LastEvaluatedKey) break;
        lastKey = locResult.LastEvaluatedKey;
      }
      // For live poll results came descending — reverse to get chronological order
      if (isLivePoll) locationHistory.reverse();
      // Use the newest history point as lastLocation
      if (locationHistory.length > 0) {
        lastLocation = locationHistory[locationHistory.length - 1];
      }
    } catch (locErr) {
      console.error("trackByToken location fetch error:", locErr);
    }

    const safeLoad = {
      id:              load.id,
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
      dispatcherEmail: load.dispatcherEmail || null,
      companyName:     load.companyName || null,
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
