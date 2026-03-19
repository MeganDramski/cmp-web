// src/handlers/sendDriverLink.js
// POST /loads/{id}/send-driver-link
// Dispatcher calls this after creating a load.
// 1. Looks up the load from DynamoDB
// 2. Texts the driver a browser-based tracking link via Amazon SNS
// 3. Emails the dispatcher a "driver notified" confirmation
// 4. If notifyCustomer=true → emails the customer a "shipment started" notice
//
// Body: { driverPhone, dispatcherEmail, notifyCustomer?: boolean }

const { DynamoDBClient, GetItemCommand, QueryCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { verifyToken, respond } = require("../utils/auth");

const db  = new DynamoDBClient({});
const sns = new SNSClient({});
const ses = new SESClient({});

const LOADS_TABLE  = process.env.LOADS_TABLE;
const FROM_EMAIL   = process.env.SES_FROM_EMAIL;
// TRACKING_BASE_URL is built at runtime from the request so we avoid a
// CloudFormation circular dependency between Lambda and API Gateway.
function getBaseUrl(event) {
  const domain  = event.requestContext?.domainName;
  const stage   = event.requestContext?.stage;
  if (domain && stage) return `https://${domain}/${stage}`;
  return process.env.TRACKING_BASE_URL || '';
}
// CloudFormation circular dependency between Lambda and API Gateway.
function getBaseUrl(event) {
  const domain  = event.requestContext?.domainName;
  const stage   = event.requestContext?.stage;
  if (domain && stage) return `https://${domain}/${stage}`;
  return process.env.TRACKING_BASE_URL || '';
}

exports.handler = async (event) => {
  try {
    verifyToken(event);  // must be a dispatcher

    const loadId = event.pathParameters?.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    const body = JSON.parse(event.body || "{}");
    const { driverPhone, dispatcherEmail, notifyCustomer = false } = body;

    if (!driverPhone) return respond(400, { error: "driverPhone is required." });
    if (!dispatcherEmail) return respond(400, { error: "dispatcherEmail is required." });

    // ── 1. Fetch the load ────────────────────────────────────────────────────
    const loadResult = await db.send(new GetItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: loadId }),
    }));
    if (!loadResult.Item) return respond(404, { error: "Load not found." });
    const load = unmarshall(loadResult.Item);

    // ── 2. Build driver browser link ─────────────────────────────────────────
    // The link opens a plain HTML page — no app required
    const driverLink = `${getBaseUrl(event)}/driver-tracking.html?token=${load.trackingToken}&loadId=${load.id}`;

    // ── 3. SMS driver via SNS ────────────────────────────────────────────────
    const smsMessage =
      `CMP Freight – Load ${load.loadNumber}\n` +
      `Pickup: ${load.pickupAddress}\n` +
      `Delivery: ${load.deliveryAddress}\n\n` +
      `Tap here to start tracking:\n${driverLink}`;

    try {
      await sns.send(new PublishCommand({
        PhoneNumber: driverPhone.replace(/[^\d+]/g, ""), // strip formatting
        Message: smsMessage,
        MessageAttributes: {
          "AWS.SNS.SMS.SenderID": { DataType: "String", StringValue: "CMPFreight" },
          "AWS.SNS.SMS.SMSType":  { DataType: "String", StringValue: "Transactional" },
        },
      }));
    } catch (snsErr) {
      console.warn("SNS SMS failed (continuing):", snsErr.message);
    }

    // ── 4. Email dispatcher confirmation ─────────────────────────────────────
    if (FROM_EMAIL) {
      try {
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [dispatcherEmail] },
          Message: {
            Subject: { Data: `✅ Driver notified – Load ${load.loadNumber}` },
            Body: {
              Html: {
                Data: `
                  <p>The driver has been sent a tracking link via SMS to <strong>${driverPhone}</strong>.</p>
                  <p><strong>Load:</strong> ${load.loadNumber}<br>
                  <strong>Driver:</strong> ${load.assignedDriverName || "Assigned Driver"}<br>
                  <strong>Pickup:</strong> ${load.pickupAddress}<br>
                  <strong>Delivery:</strong> ${load.deliveryAddress}</p>
                  <p>You will receive another email when the driver taps <em>Start Tracking</em>.</p>
                  <p style="color:#888;font-size:12px;">– CMP Freight Tracking</p>
                `,
              },
            },
          },
        }));
      } catch (sesErr) {
        console.warn("SES dispatcher email failed (continuing):", sesErr.message);
      }
    }

    // ── 5. Optionally email customer "shipment assigned" notice ──────────────
    if (notifyCustomer && load.customerEmail && FROM_EMAIL) {
      try {
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [load.customerEmail] },
          Message: {
            Subject: { Data: `Your shipment ${load.loadNumber} has been assigned a driver` },
            Body: {
              Html: {
                Data: `
                  <p>Hello <strong>${load.customerName}</strong>,</p>
                  <p>Your shipment <strong>${load.loadNumber}</strong> has been assigned to a driver
                  and will be on its way soon.</p>
                  <p>You will receive another email with a live tracking link once the driver
                  starts the trip.</p>
                  <table style="border-collapse:collapse;margin-top:12px;">
                    <tr><td style="padding:4px 12px 4px 0;color:#666;">Pickup</td>
                        <td style="padding:4px 0;">${load.pickupAddress}</td></tr>
                    <tr><td style="padding:4px 12px 4px 0;color:#666;">Delivery</td>
                        <td style="padding:4px 0;">${load.deliveryAddress}</td></tr>
                    <tr><td style="padding:4px 12px 4px 0;color:#666;">Est. Delivery</td>
                        <td style="padding:4px 0;">${load.deliveryDate || "TBD"}</td></tr>
                  </table>
                  <p style="color:#888;font-size:12px;">– CMP Freight</p>
                `,
              },
            },
          },
        }));
      } catch (sesErr) {
        console.warn("SES customer assignment email failed (continuing):", sesErr.message);
      }
    }

    return respond(200, {
      success: true,
      driverLinkSent: true,
      driverPhone,
      notifyCustomer,
    });
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("sendDriverLink error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
