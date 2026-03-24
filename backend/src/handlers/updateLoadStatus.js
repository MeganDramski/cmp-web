// src/handlers/updateLoadStatus.js
// PATCH /loads/{id}/status

const { DynamoDBClient, UpdateItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { verifyToken, respond } = require("../utils/auth");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const TABLE      = process.env.LOADS_TABLE;
const FROM_EMAIL = process.env.SES_FROM_EMAIL;
const BASE_URL   = (process.env.AMPLIFY_BASE_URL || process.env.TRACKING_BASE_URL || "").replace(/\/$/, "");

const VALID_STATUSES = ["Pending", "Assigned", "Accepted", "In Transit", "Delivered", "Cancelled"];

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);

    const loadId = event.pathParameters?.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    const body = JSON.parse(event.body || "{}");
    if (!VALID_STATUSES.includes(body.status)) {
      return respond(400, { error: `status must be one of: ${VALID_STATUSES.join(", ")}` });
    }

    // Tenant isolation: check load ownership before update (skip for public token-based calls)
    if (user.tenantId) {
      const check = await db.send(new GetItemCommand({
        TableName: TABLE,
        Key: marshall({ id: loadId }),
      }));
      if (check.Item) {
        const existingLoad = unmarshall(check.Item);
        if (existingLoad.tenantId && existingLoad.tenantId !== user.tenantId) {
          return respond(403, { error: "You do not have permission to update this load." });
        }
      }
    }

    const now = new Date().toISOString();

    await db.send(new UpdateItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
      UpdateExpression: "SET #s = :s, updatedAt = :t",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: marshall({ ":s": body.status, ":t": now }),
    }));

    // ── Send email notifications on key status changes ────────────────────
    if (FROM_EMAIL && (body.status === "Delivered" || body.status === "In Transit")) {
      try {
        const getResult = await db.send(new GetItemCommand({
          TableName: TABLE,
          Key: marshall({ id: loadId }),
        }));
        const load = getResult.Item ? unmarshall(getResult.Item) : null;

        if (load) {
          const dispatcherEmail = load.dispatcherEmail || load.createdBy || load.assignedByEmail;
          const deliveredTime = new Date(now).toLocaleString("en-US", {
            month: "short", day: "numeric", year: "numeric",
            hour: "numeric", minute: "2-digit", timeZoneName: "short",
          });

          if (body.status === "Delivered") {
            // ── Delivery confirmation to dispatcher ──
            if (dispatcherEmail) {
              await ses.send(new SendEmailCommand({
                Source: FROM_EMAIL,
                Destination: { ToAddresses: [dispatcherEmail] },
                Message: {
                  Subject: { Data: `\u2705 Delivered \u2013 Load ${load.loadNumber}` },
                  Body: {
                    Html: {
                      Data: `<!DOCTYPE html><html><body style="margin:0;padding:0;background:#f4f4f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:520px;margin:32px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
  <div style="background:#34C759;padding:24px 28px;">
    <div style="font-size:22px;font-weight:700;color:#fff;">\u2705 Load Delivered Successfully</div>
    <div style="color:rgba(255,255,255,.8);font-size:14px;margin-top:4px;">Load ${load.loadNumber} has been delivered</div>
  </div>
  <div style="padding:24px 28px;">
    <table style="width:100%;border-collapse:collapse;font-size:14px;">
      <tr><td style="padding:8px 0;color:#888;width:120px;">Driver</td><td style="padding:8px 0;font-weight:600;">${load.assignedDriverName || "\u2014"}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Load #</td><td style="padding:8px 0;font-weight:600;">${load.loadNumber}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Customer</td><td style="padding:8px 0;">${load.customerName || "\u2014"}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Pickup</td><td style="padding:8px 0;">${load.pickupAddress}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Delivery</td><td style="padding:8px 0;">${load.deliveryAddress}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Delivered At</td><td style="padding:8px 0;font-weight:600;color:#34C759;">${deliveredTime}</td></tr>
    </table>
    <p style="font-size:12px;color:#aaa;margin-top:20px;text-align:center;">\u2013 CMP Logistics Tracking</p>
  </div>
</div></body></html>`,
                    },
                  },
                },
              }));
              console.log("updateLoadStatus: delivery email sent to dispatcher:", dispatcherEmail);
            }

            // ── Delivery confirmation to customer ──
            if (load.notifyCustomer && load.customerEmail) {
              await ses.send(new SendEmailCommand({
                Source: FROM_EMAIL,
                Destination: { ToAddresses: [load.customerEmail] },
                Message: {
                  Subject: { Data: `\u2705 Your shipment ${load.loadNumber} has been delivered!` },
                  Body: {
                    Html: {
                      Data: `<!DOCTYPE html><html><body style="margin:0;padding:0;background:#f4f4f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
<div style="max-width:520px;margin:32px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
  <div style="background:#34C759;padding:24px 28px;">
    <div style="font-size:22px;font-weight:700;color:#fff;">\u2705 Shipment Delivered!</div>
    <div style="color:rgba(255,255,255,.8);font-size:14px;margin-top:4px;">Your shipment ${load.loadNumber} has arrived</div>
  </div>
  <div style="padding:24px 28px;">
    <p style="font-size:15px;margin:0 0 12px;">Hello <strong>${load.customerName || "Valued Customer"}</strong>,</p>
    <p style="font-size:14px;color:#555;margin:0 0 16px;">Your shipment has been successfully delivered.</p>
    <table style="width:100%;border-collapse:collapse;font-size:14px;margin:0 0 20px;">
      <tr><td style="padding:8px 0;color:#888;width:120px;">Load #</td><td style="padding:8px 0;font-weight:600;">${load.loadNumber}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Delivered At</td><td style="padding:8px 0;font-weight:600;color:#34C759;">${deliveredTime}</td></tr>
      <tr style="border-top:1px solid #f0f0f0;"><td style="padding:8px 0;color:#888;">Delivery Address</td><td style="padding:8px 0;">${load.deliveryAddress}</td></tr>
    </table>
    <p style="font-size:12px;color:#aaa;margin-top:20px;text-align:center;">Thank you for choosing CMP Logistics \u2013</p>
  </div>
</div></body></html>`,
                    },
                  },
                },
              }));
              console.log("updateLoadStatus: delivery email sent to customer:", load.customerEmail);
            }
          }
        }
      } catch (emailErr) {
        // Never let email failure break the status update response
        console.error("updateLoadStatus: email notification failed:", emailErr.message);
      }
    }

    return respond(200, { id: loadId, status: body.status });
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("updateLoadStatus error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
