// src/handlers/startTracking.js
// POST /track/{token}/start

const { DynamoDBClient, QueryCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const LOADS_TABLE = process.env.LOADS_TABLE;
const FROM_EMAIL  = process.env.SES_FROM_EMAIL;
const BASE_URL    = (process.env.AMPLIFY_BASE_URL || process.env.TRACKING_BASE_URL || "").replace(/\/$/, "");

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  try {
    const token = event.pathParameters?.token;
    if (!token) return respond(400, { error: "Tracking token required." });

    const body = JSON.parse(event.body || "{}");
    const { latitude, longitude, dispatcherEmail, notifyCustomer = false } = body;

    // 1. Look up load by trackingToken (GSI)
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

    // 2. Update load status → In Transit + record startedAt
    const now = new Date().toISOString();
    const updateExpr = latitude != null
      ? "SET #st = :status, startedAt = :now, lastLocation = :loc"
      : "SET #st = :status, startedAt = :now";
    const exprAttrValues = latitude != null
      ? marshall({ ":status": "In Transit", ":now": now,
          ":loc": { latitude: Number(latitude), longitude: Number(longitude), timestamp: now } })
      : marshall({ ":status": "In Transit", ":now": now });

    await db.send(new UpdateItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: load.id }),
      UpdateExpression: updateExpr,
      ExpressionAttributeNames: { "#st": "status" },
      ExpressionAttributeValues: exprAttrValues,
    }));

    // 3. Email dispatcher
    // Check every possible field where the dispatcher email may be stored
    const emailRecipient = dispatcherEmail
      || load.dispatcherEmail
      || load.createdBy
      || load.assignedByEmail;

    console.log("startTracking: FROM_EMAIL =", FROM_EMAIL, "| recipient =", emailRecipient);

    if (FROM_EMAIL && emailRecipient) {
      try {
        const mapsLink = latitude != null
          ? `https://maps.google.com/?q=${latitude},${longitude}` : null;
        const trackURL = `${BASE_URL}/track-shipment.html?token=${load.trackingToken}`;
        const startedTime = new Date(now).toLocaleString("en-US", {
          month: "short", day: "numeric", year: "numeric",
          hour: "numeric", minute: "2-digit", timeZoneName: "short",
        });

        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [emailRecipient] },
          Message: {
            Subject: { Data: `\uD83D\uDE9B Driver started \u2013 Load ${load.loadNumber}` },
            Body: {
              Html: {
                Data: `<!DOCTYPE html><html><body style="margin:0;padding:0;background:#f4f4f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:520px;margin:32px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
  <div style="background:#007AFF;padding:24px 28px;">
    <div style="font-size:22px;font-weight:700;color:#fff;">\uD83D\uDE9B Driver Started Tracking</div>
    <div style="color:rgba(255,255,255,.8);font-size:14px;margin-top:4px;">Load ${load.loadNumber} is now In Transit</div>
  </div>
  <div style="padding:24px 28px;">
    <table style="width:100%;border-collapse:collapse;font-size:14px;">
      <tr><td style="padding:8px 0;color:#888;width:120px;">Driver</td><td style="padding:8px 0;font-weight:600;">${load.assignedDriverName || "\u2014"}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Load #</td><td style="padding:8px 0;font-weight:600;">${load.loadNumber}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Pickup</td><td style="padding:8px 0;">${load.pickupAddress}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Delivery</td><td style="padding:8px 0;">${load.deliveryAddress}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Customer</td><td style="padding:8px 0;">${load.customerName || "\u2014"}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Started</td><td style="padding:8px 0;">${startedTime}</td></tr>
    </table>
    ${mapsLink ? `<a href="${mapsLink}" style="display:block;margin:20px 0 12px;background:#34C759;color:#fff;text-align:center;padding:13px;border-radius:10px;text-decoration:none;font-weight:700;font-size:15px;">\uD83D\uDCCD View Current Location</a>` : ""}
    <a href="${trackURL}" style="display:block;margin:${mapsLink ? "0" : "20px 0 12px"};background:#f0f7ff;color:#007AFF;text-align:center;padding:13px;border-radius:10px;text-decoration:none;font-weight:700;font-size:15px;border:1px solid #cce0ff;">\uD83D\uDDFA Open Live Tracking Page</a>
    <p style="font-size:12px;color:#aaa;margin-top:20px;text-align:center;">\u2013 CMP Freight Tracking</p>
  </div>
</div></body></html>`,
              },
            },
          },
        }));
        console.log("startTracking: dispatcher email sent to", emailRecipient);
      } catch (err) {
        console.error("SES dispatcher email failed:", err.message);
      }
    } else {
      console.warn("startTracking: skipping dispatcher email — FROM_EMAIL:", FROM_EMAIL, "| recipient:", emailRecipient);
    }

    // 4. Email customer with live tracking link
    const shouldNotify = notifyCustomer || load.notifyCustomer;
    if (shouldNotify && FROM_EMAIL && load.customerEmail) {
      try {
        const trackURL = `${BASE_URL}/track-shipment.html?token=${load.trackingToken}`;
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [load.customerEmail] },
          Message: {
            Subject: { Data: `\uD83D\uDCE6 Your shipment ${load.loadNumber} is on its way!` },
            Body: {
              Html: {
                Data: `<!DOCTYPE html><html><body style="margin:0;padding:0;background:#f4f4f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:520px;margin:32px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
  <div style="background:#34C759;padding:24px 28px;">
    <div style="font-size:22px;font-weight:700;color:#fff;">\uD83D\uDCE6 Your Shipment Is On Its Way!</div>
    <div style="color:rgba(255,255,255,.8);font-size:14px;margin-top:4px;">Load ${load.loadNumber} is now in transit</div>
  </div>
  <div style="padding:24px 28px;">
    <p style="font-size:15px;margin:0 0 12px;">Hello <strong>${load.customerName || "Valued Customer"}</strong>,</p>
    <table style="width:100%;border-collapse:collapse;font-size:14px;margin:0 0 20px;">
      <tr><td style="padding:8px 0;color:#888;width:120px;">Load #</td><td style="padding:8px 0;font-weight:600;">${load.loadNumber}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Pickup</td><td style="padding:8px 0;">${load.pickupAddress}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Delivery</td><td style="padding:8px 0;">${load.deliveryAddress}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Est. Delivery</td><td style="padding:8px 0;">${load.deliveryDate || "TBD"}</td></tr>
    </table>
    <a href="${trackURL}" style="display:block;background:#007AFF;color:#fff;text-align:center;padding:14px;border-radius:10px;text-decoration:none;font-weight:700;font-size:16px;">\uD83D\uDCCD Track My Shipment Live</a>
    <p style="font-size:12px;color:#aaa;margin-top:20px;text-align:center;">\u2013 CMP Freight</p>
  </div>
</div></body></html>`,
              },
            },
          },
        }));
        console.log("startTracking: customer email sent to", load.customerEmail);
      } catch (err) {
        console.error("SES customer email failed:", err.message);
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
