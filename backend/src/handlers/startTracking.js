// src/handlers/startTracking.js
// POST /track/{token}/start
// Called from the browser-based driver tracking page when the driver
// taps "Start Tracking".
//
// 1. Marks load status = "In Transit" in DynamoDB
// 2. Sends email to dispatcher: "Driver has started tracking"
// 3. If notifyCustomer flag is set on the load → sends email to customer
//    with a live tracking link they can open in their browser

const { DynamoDBClient, QueryCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const LOADS_TABLE  = process.env.LOADS_TABLE;
const FROM_EMAIL   = process.env.SES_FROM_EMAIL;
// Use the Amplify frontend URL so links in emails open the HTML pages,
// not the API Gateway endpoint (which only serves JSON).
const BASE_URL     = (process.env.AMPLIFY_BASE_URL || process.env.TRACKING_BASE_URL || "").replace(/\/$/, "");

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
    if (!token) return respond(400, { error: "Tracking token required." });

    const body = JSON.parse(event.body || "{}");
    const { latitude, longitude, dispatcherEmail, notifyCustomer = false } = body;

    // ── 1. Look up load by trackingToken (GSI) ───────────────────────────────
    const loadResult = await db.send(new QueryCommand({
      TableName: LOADS_TABLE,
      IndexName: "TrackingTokenIndex",
      KeyConditionExpression: "trackingToken = :t",
      ExpressionAttributeValues: marshall({ ":t": token }),
      Limit: 1,
    }));

    if (!loadResult.Items || loadResult.Items.length === 0) {
      return respond(404, { error: "No shipment found for this tracking link." });
    }

    const load = unmarshall(loadResult.Items[0]);

    // ── 2. Update load status → In Transit ──────────────────────────────────
    const now = new Date().toISOString();
    const updateExpr = latitude != null
      ? "SET #st = :status, startedAt = :now, lastLocation = :loc"
      : "SET #st = :status, startedAt = :now";

    const exprAttrValues = latitude != null
      ? marshall({
          ":status": "In Transit",
          ":now": now,
          ":loc": { latitude: Number(latitude), longitude: Number(longitude), timestamp: now },
        })
      : marshall({ ":status": "In Transit", ":now": now });

    await db.send(new UpdateItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: load.id }),
      UpdateExpression: updateExpr,
      ExpressionAttributeNames: { "#st": "status" },
      ExpressionAttributeValues: exprAttrValues,
    }));

    // ── 3. Email dispatcher ─────────────────────────────────────────────────
    const emailRecipient = dispatcherEmail || load.dispatcherEmail || load.createdBy;
    if (FROM_EMAIL && emailRecipient) {
      try {
        const mapsLink = latitude != null
          ? `https://maps.google.com/?q=${latitude},${longitude}`
          : null;
        const customerTrackURL = `${BASE_URL}/track-shipment.html?token=${load.trackingToken}`;
        const startedTime = new Date(now).toLocaleString("en-US", {
          month: "short", day: "numeric", year: "numeric",
          hour: "numeric", minute: "2-digit", timeZoneName: "short"
        });

        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [emailRecipient] },
          Message: {
            Subject: { Data: `🚛 Driver started – Load ${load.loadNumber}` },
            Body: {
              Html: {
                Data: `
<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;background:#f4f4f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
  <div style="max-width:520px;margin:32px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
    <div style="background:#007AFF;padding:24px 28px;">
      <div style="font-size:22px;font-weight:700;color:#fff;">🚛 Driver Started Tracking</div>
      <div style="color:rgba(255,255,255,.8);font-size:14px;margin-top:4px;">Load ${load.loadNumber} is now In Transit</div>
    </div>
    <div style="padding:24px 28px;">
      <table style="width:100%;border-collapse:collapse;font-size:14px;">
        <tr><td style="padding:8px 0;color:#888;width:120px;">Driver</td><td style="padding:8px 0;font-weight:600;">${load.assignedDriverName || "—"}</td></tr>
        <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Load #</td><td style="padding:8px 0;font-weight:600;">${load.loadNumber}</td></tr>
        <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Pickup</td><td style="padding:8px 0;">${load.pickupAddress}</td></tr>
        <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Delivery</td><td style="padding:8px 0;">${load.deliveryAddress}</td></tr>
        <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Customer</td><td style="padding:8px 0;">${load.customerName || "—"}</td></tr>
        <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Started</td><td style="padding:8px 0;">${startedTime}</td></tr>
      </table>

      ${mapsLink ? `
      <a href="${mapsLink}" style="display:block;margin:20px 0 12px;background:#34C759;color:#fff;text-align:center;padding:13px;border-radius:10px;text-decoration:none;font-weight:700;font-size:15px;">
        📍 View Current Location on Map
      </a>` : ""}

      <a href="${customerTrackURL}" style="display:block;margin:${mapsLink ? "0" : "20px 0 12px"};background:#f0f7ff;color:#007AFF;text-align:center;padding:13px;border-radius:10px;text-decoration:none;font-weight:700;font-size:15px;border:1px solid #cce0ff;">
        🗺 Open Live Tracking Page
      </a>

      <p style="font-size:12px;color:#aaa;margin-top:20px;text-align:center;">– CMP Freight Tracking</p>
    </div>
  </div>
</body>
</html>`,
              },
            },
          },
        }));
      } catch (err) {
        console.warn("SES dispatcher start email failed:", err.message);
      }
    }

    // ── 4. Email customer with live tracking link ────────────────────────────
    const shouldNotify = notifyCustomer || load.notifyCustomer;
    if (shouldNotify && FROM_EMAIL && load.customerEmail) {
      try {
        const trackURL = `${BASE_URL}/track-shipment.html?token=${load.trackingToken}`;
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [load.customerEmail] },
          Message: {
            Subject: { Data: `📦 Your shipment ${load.loadNumber} is on its way!` },
            Body: {
              Html: {
                Data: `
                  <p>Hello <strong>${load.customerName}</strong>,</p>
                  <p>Your shipment is now in transit!</p>
                  <p style="margin:20px 0;">
                    <a href="${trackURL}"
                       style="background:#007AFF;color:white;padding:12px 28px;
                              border-radius:8px;text-decoration:none;font-weight:bold;font-size:16px;">
                      📍 Track My Shipment
                    </a>
                  </p>
                  <table style="border-collapse:collapse;margin:12px 0;">
                    <tr><td style="padding:4px 12px 4px 0;color:#666;">Load #</td>
                        <td>${load.loadNumber}</td></tr>
                    <tr><td style="padding:4px 12px 4px 0;color:#666;">Pickup</td>
                        <td>${load.pickupAddress}</td></tr>
                    <tr><td style="padding:4px 12px 4px 0;color:#666;">Delivery</td>
                        <td>${load.deliveryAddress}</td></tr>
                    <tr><td style="padding:4px 12px 4px 0;color:#666;">Est. Delivery</td>
                        <td>${load.deliveryDate || "TBD"}</td></tr>
                  </table>
                  <p style="color:#888;font-size:12px;">
                    This link is unique to your shipment.<br>– CMP Freight
                  </p>
                `,
              },
            },
          },
        }));
      } catch (err) {
        console.warn("SES customer tracking email failed:", err.message);
      }
    }

    return respond(200, {
      success: true,
      loadId: load.id,
      loadNumber: load.loadNumber,
      status: "In Transit",
      trackingToken: load.trackingToken,
      customerNotified: !!(shouldNotify && load.customerEmail),
    });
  } catch (err) {
    console.error("startTracking error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
