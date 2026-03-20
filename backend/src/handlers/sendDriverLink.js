// sendDriverLink.js – sends SMS via AWS SNS + confirmation email via SES
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
  // Ensure E.164 format (add +1 for US numbers if missing country code)
  const e164 = phone.startsWith("+") ? phone : "+1" + phone;

  const result = await sns.send(new PublishCommand({
    PhoneNumber: e164,
    Message: message,
    MessageAttributes: {
      "AWS.SNS.SMS.SMSType": {
        DataType: "String",
        StringValue: "Transactional", // higher delivery priority
      },
      "AWS.SNS.SMS.SenderID": {
        DataType: "String",
        StringValue: "CMPFreight",    // shown as sender name where supported
      },
    },
  }));
  console.log("SNS SMS sent, MessageId:", result.MessageId);
  return true;
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
      "CMP Freight - Load " + load.loadNumber + "\n" +
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

    // 4. Email dispatcher confirmation
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
                  (smsError ? "<p style='color:red;'>Error: " + smsError + "</p>" : "") +
                  "<p><strong>Load:</strong> " + load.loadNumber + "<br>" +
                  "<strong>Driver:</strong> " + (load.assignedDriverName || "Driver") + "<br>" +
                  "<strong>Pickup:</strong> " + load.pickupAddress + "<br>" +
                  "<strong>Delivery:</strong> " + load.deliveryAddress + "</p>" +
                  "<p>Driver link: <a href='" + link + "'>" + link + "</a></p>" +
                  "<p style='color:#888;font-size:12px;'>- CMP Freight Tracking</p>",
              },
            },
          },
        }));
      } catch (e) {
        console.warn("Dispatcher email failed:", e.message);
      }
    }

    // 5. Optionally notify customer
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
                  "<p style='color:#888;font-size:12px;'>- CMP Freight</p>",
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
