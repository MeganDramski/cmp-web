// sendDriverLink.js – sends SMS via AWS SNS + email via SES (both free on AWS)
const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");
const { verifyToken, respond } = require("../utils/auth");

const db  = new DynamoDBClient({ region: "us-east-1" });
const ses = new SESClient({ region: "us-east-1" });
const sns = new SNSClient({ region: "us-east-1" });

const LOADS_TABLE = process.env.LOADS_TABLE;
const FROM_EMAIL  = process.env.SES_FROM_EMAIL;
const AMPLIFY_URL = process.env.AMPLIFY_BASE_URL || "";

function buildLink(event, token, id) {
  const base = AMPLIFY_URL || (function() {
    const d = event.requestContext && event.requestContext.domainName;
    const s = event.requestContext && event.requestContext.stage;
    return d ? ("https://" + d + (s && s !== "$default" ? "/" + s : "")) : "";
  })();
  return base + "/driver-tracking.html?token=" + token + "&loadId=" + id;
}

async function sendSMS(to, message) {
  const phone = to.replace(/[^\d+]/g, "");
  const e164  = phone.startsWith("+") ? phone : "+1" + phone;
  const result = await sns.send(new PublishCommand({
    PhoneNumber: e164,
    Message: message,
    MessageAttributes: {
      "AWS.SNS.SMS.SMSType": { DataType: "String", StringValue: "Transactional" },
    },
  }));
  console.log("SNS SMS sent, MessageId:", result.MessageId);
  return true;
}

async function sendDriverEmail(driverEmail, driverName, load, link) {
  if (!driverEmail || !FROM_EMAIL) return;
  await ses.send(new SendEmailCommand({
    Source: FROM_EMAIL,
    Destination: { ToAddresses: [driverEmail] },
    Message: {
      Subject: { Data: "CMP Logistics – Load " + load.loadNumber + " assigned to you" },
      Body: {
        Html: {
          Data:
            "<p>Hi <strong>" + (driverName || "Driver") + "</strong>,</p>" +
            "<p>You have a new load assigned by CMP Logistics.</p>" +
            "<table style='font-family:sans-serif;font-size:14px;'>" +
            "<tr><td><strong>Load #:</strong></td><td>" + load.loadNumber + "</td></tr>" +
            "<tr><td><strong>Pickup:</strong></td><td>" + load.pickupAddress + "</td></tr>" +
            "<tr><td><strong>Delivery:</strong></td><td>" + load.deliveryAddress + "</td></tr>" +
            "</table>" +
            "<p style='margin-top:20px;'>" +
            "<a href='" + link + "' style='background:#007AFF;color:#fff;padding:14px 28px;border-radius:10px;text-decoration:none;font-weight:700;font-size:16px;'>Open Tracking Link</a>" +
            "</p>" +
            "<p style='color:#888;font-size:12px;margin-top:20px;'>No app needed – works in any browser.</p>",
        },
      },
    },
  }));
}

exports.handler = async (event) => {
  try {
    verifyToken(event);

    const loadId = event.pathParameters && event.pathParameters.id;
    if (!loadId) return respond(400, { error: "Load ID required" });

    const body = JSON.parse(event.body || "{}");
    const { driverPhone, dispatcherEmail, notifyCustomer = false } = body;
    if (!driverPhone)     return respond(400, { error: "driverPhone required" });
    if (!dispatcherEmail) return respond(400, { error: "dispatcherEmail required" });

    // 1. Fetch load
    const res = await db.send(new GetItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: loadId }),
    }));
    if (!res.Item) return respond(404, { error: "Load not found" });
    const load = unmarshall(res.Item);

    // 2. Build tracking link
    const link = buildLink(event, load.trackingToken, load.id);

    // 3. Send SMS via AWS SNS
    const smsText =
      "CMP Logistics - Load " + load.loadNumber + "\n" +
      "Pickup: " + load.pickupAddress + "\n" +
      "Deliver to: " + load.deliveryAddress + "\n\n" +
      "Tap to start tracking:\n" + link;

    let smsSent = false;
    let smsError = null;
    try {
      smsSent = await sendSMS(driverPhone, smsText);
    } catch (e) {
      console.warn("SMS failed:", e.message);
      smsError = e.message;
    }

    // 4. Send email to driver as backup (if email on file)
    try {
      await sendDriverEmail(load.assignedDriverEmail, load.assignedDriverName, load, link);
    } catch (e) {
      console.warn("Driver email failed:", e.message);
    }

    // 5. Email dispatcher confirmation
    if (FROM_EMAIL) {
      try {
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [dispatcherEmail] },
          Message: {
            Subject: { Data: "Driver notified - Load " + load.loadNumber },
            Body: {
              Html: {
                Data:
                  "<p>SMS " + (smsSent ? "sent ✅" : "could not be sent ⚠️") + " to <strong>" + driverPhone + "</strong>.</p>" +
                  (smsError ? "<p style='color:orange;'>SMS Error: " + smsError + "</p><p>The driver tracking link was sent by <strong>email</strong> instead.</p>" : "") +
                  "<p><strong>Load:</strong> " + load.loadNumber + "<br>" +
                  "<strong>Driver:</strong> " + (load.assignedDriverName || "Driver") + "<br>" +
                  "<strong>Pickup:</strong> " + load.pickupAddress + "<br>" +
                  "<strong>Delivery:</strong> " + load.deliveryAddress + "</p>" +
                  "<p>Driver link: <a href='" + link + "'>" + link + "</a></p>",
              },
            },
          },
        }));
      } catch (e) {
        console.warn("Dispatcher email failed:", e.message);
      }
    }

    // 6. Optionally notify customer
    if (notifyCustomer && load.customerEmail && FROM_EMAIL) {
      try {
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [load.customerEmail] },
          Message: {
            Subject: { Data: "Shipment " + load.loadNumber + " – driver assigned" },
            Body: {
              Html: {
                Data:
                  "<p>Hello <strong>" + load.customerName + "</strong>,</p>" +
                  "<p>Your shipment <strong>" + load.loadNumber + "</strong> has been assigned a driver. " +
                  "You will receive a live tracking link once the driver starts the trip.</p>" +
                  "<p style='color:#888;font-size:12px;'>- CMP Logistics</p>",
              },
            },
          },
        }));
      } catch (e) {
        console.warn("Customer email failed:", e.message);
      }
    }

    return respond(200, { success: true, smsSent, smsError, driverLink: link });

  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("sendDriverLink error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
