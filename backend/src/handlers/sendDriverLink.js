// sendDriverLink.js – sends SMS via Twilio + confirmation email via SES
const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { verifyToken, respond } = require("../utils/auth");

const db  = new DynamoDBClient({ region: "us-east-1" });
const ses = new SESClient({ region: "us-east-1" });

const LOADS_TABLE  = process.env.LOADS_TABLE;
const FROM_EMAIL   = process.env.SES_FROM_EMAIL;
const TWILIO_SID   = process.env.TWILIO_ACCOUNT_SID;
const TWILIO_TOKEN = process.env.TWILIO_AUTH_TOKEN;
const TWILIO_FROM  = process.env.TWILIO_FROM_NUMBER;
const AMPLIFY_URL  = process.env.AMPLIFY_BASE_URL || "";

function buildLink(event, token, id) {
  const base = AMPLIFY_URL || (function() {
    const d = event.requestContext && event.requestContext.domainName;
    const s = event.requestContext && event.requestContext.stage;
    return d ? ("https://" + d + (s && s !== "$default" ? "/" + s : "")) : "";
  })();
  return base + "/driver-tracking.html?token=" + token + "&loadId=" + id;
}

async function sendSMS(to, body) {
  if (!TWILIO_SID || !TWILIO_TOKEN || !TWILIO_FROM) {
    console.warn("Twilio not configured – skipping SMS");
    return false;
  }
  const url  = "https://api.twilio.com/2010-04-01/Accounts/" + TWILIO_SID + "/Messages.json";
  const auth = Buffer.from(TWILIO_SID + ":" + TWILIO_TOKEN).toString("base64");
  const r = await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": "Basic " + auth,
      "Content-Type":  "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ To: to, From: TWILIO_FROM, Body: body }).toString(),
  });
  const d = await r.json();
  if (!r.ok) throw new Error("Twilio error: " + d.message);
  console.log("SMS sent:", d.sid);
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

    // 3. Send SMS via Twilio
    const smsText =
      "CMP Freight - Load " + load.loadNumber + "\n" +
      "Pickup: " + load.pickupAddress + "\n" +
      "Deliver to: " + load.deliveryAddress + "\n\n" +
      "Tap to start tracking:\n" + link;

    let smsSent = false;
    let smsError = null;
    try {
      smsSent = await sendSMS(driverPhone.replace(/[^\d+]/g, ""), smsText);
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
                  "<p>SMS " + (smsSent ? "sent" : "could not be sent") + " to <strong>" + driverPhone + "</strong>.</p>" +
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
    return respond(500, { error: "Internal server error
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
    return respond(500, { error: "Internal server error.
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
