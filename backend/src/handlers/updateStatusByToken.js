// src/handlers/updateStatusByToken.js
// PATCH /track/{token}/status
//
// Public endpoint — no JWT required. Driver web page uses this to update
// load status (Accepted, In Transit, Delivered) using only the tracking token.
// Accepts optional loadId in the body for a direct GetItem lookup (faster,
// no GSI dependency).

const { DynamoDBClient, GetItemCommand, QueryCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const LOADS_TABLE = process.env.LOADS_TABLE;
const FROM_EMAIL  = process.env.SES_FROM_EMAIL;
const BASE_URL    = (process.env.AMPLIFY_BASE_URL || process.env.TRACKING_BASE_URL || "").replace(/\/$/, "");

const ALLOWED_STATUSES = ["Accepted", "In Transit", "Delivered", "Cancelled"];

const CORS_HEADERS = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Methods": "GET,POST,PATCH,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type,Authorization",
};

function respond(statusCode, body) {
  return { statusCode, headers: CORS_HEADERS, body: JSON.stringify(body) };
}

exports.handler = async (event) => {
  // Handle CORS preflight
  if (event.requestContext?.http?.method === "OPTIONS" || event.httpMethod === "OPTIONS") {
    return { statusCode: 200, headers: CORS_HEADERS, body: "" };
  }
  try {
    const token = event.pathParameters?.token;
    if (!token) return respond(400, { error: "Tracking token required." });

    const body   = JSON.parse(event.body || "{}");
    const status = body.status;
    if (!ALLOWED_STATUSES.includes(status)) {
      return respond(400, { error: `status must be one of: ${ALLOWED_STATUSES.join(", ")}` });
    }

    // ── 1. Look up load ──────────────────────────────────────────────────────
    // Primary: use loadId from body (direct GetItem — no GSI needed)
    // Fallback: GSI query by trackingToken (works if GSI exists)
    let load = null;

    if (body.loadId) {
      const getResult = await db.send(new GetItemCommand({
        TableName: LOADS_TABLE,
        Key: marshall({ id: body.loadId }),
      }));
      if (getResult.Item) {
        load = unmarshall(getResult.Item);
        // Safety check: token must match to prevent spoofing
        if (load.trackingToken && load.trackingToken !== token) {
          return respond(403, { error: "Token does not match this load." });
        }
      }
    }

    // Fallback: GSI query
    if (!load) {
      try {
        const result = await db.send(new QueryCommand({
          TableName: LOADS_TABLE,
          IndexName: "TrackingTokenIndex",
          KeyConditionExpression: "trackingToken = :t",
          ExpressionAttributeValues: marshall({ ":t": token }),
          Limit: 1,
        }));
        if (result.Items && result.Items.length > 0) {
          load = unmarshall(result.Items[0]);
        }
      } catch (gsiErr) {
        console.warn("GSI lookup failed (index may not exist):", gsiErr.message);
      }
    }

    if (!load) {
      return respond(404, { error: "No shipment found for this tracking token." });
    }

    // ── 2. Update DynamoDB ───────────────────────────────────────────────────
    const now        = new Date().toISOString();
    const isTerminal = status === "Delivered" || status === "Cancelled";
    const updateExpr = isTerminal
      ? "SET #s = :s, updatedAt = :t, completedAt = :t"
      : "SET #s = :s, updatedAt = :t";

    await db.send(new UpdateItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: load.id }),
      UpdateExpression: updateExpr,
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: marshall({ ":s": status, ":t": now }),
    }));

    // ── 3. Send dispatcher email on key transitions ──────────────────────────
    if (FROM_EMAIL) {
      const dispatcherEmail = load.dispatcherEmail || load.createdBy;
      const driverName      = body.driverName || load.assignedDriverName || "Driver";
      const loadNumber      = load.loadNumber || load.id;
      const timeStr         = new Date(now).toLocaleString("en-US", {
        month: "short", day: "numeric", year: "numeric",
        hour: "numeric", minute: "2-digit", timeZoneName: "short",
      });

      try {
        if (status === "Accepted" && dispatcherEmail) {
          await ses.send(new SendEmailCommand({
            Source: FROM_EMAIL,
            Destination: { ToAddresses: [dispatcherEmail] },
            Message: {
              Subject: { Data: `👍 Load ${loadNumber} Accepted by ${driverName}` },
              Body: { Html: { Data: `<p>${driverName} accepted load <strong>${loadNumber}</strong> at ${timeStr}. They are ready at pickup time.</p>` } },
            },
          }));
        } else if (status === "Delivered" && dispatcherEmail) {
          await ses.send(new SendEmailCommand({
            Source: FROM_EMAIL,
            Destination: { ToAddresses: [dispatcherEmail] },
            Message: {
              Subject: { Data: `📦 Load ${loadNumber} Delivered by ${driverName}` },
              Body: { Html: { Data: `<p>Load <strong>${loadNumber}</strong> was marked as <strong>Delivered</strong> by ${driverName} at ${timeStr}.</p>` } },
            },
          }));
        }
      } catch (emailErr) {
        console.warn("updateStatusByToken email error:", emailErr.message);
      }
    }

    return respond(200, { message: "Status updated.", loadId: load.id, status });
  } catch (err) {
    console.error("updateStatusByToken error:", err);
    return respond(500, { error: err.message });
  }
};
