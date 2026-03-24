// sendDriverLink.js – sends driver tracking link via email (SES) and SMS (SNS)
//
// ── SNS SMS (AWS Simple Notification Service) ────────────────────────────────
// SMS sending is GATED behind the SNS_ENABLED environment variable.
//
//   SNS_ENABLED=false  (default / sandbox)  → SMS is skipped; email only.
//   SNS_ENABLED=true   (after AWS prod SMS approval) → SMS fires automatically.
//
// AWS SNS SMS requires production access approval from AWS Support before you
// can send to non-sandboxed phone numbers.  Once approved:
//   1. Set SNS_ENABLED=true in your Lambda environment variables (or SAM template).
//   2. Optionally set SNS_SENDER_ID=Routelo (for branded sender — US doesn't support it,
//      but many international countries do).
//   3. Deploy — no code change needed.
//
// IAM permission required on the Lambda execution role:
//   sns:Publish  on resource  arn:aws:sns:*:*:*  (or restrict to a specific topic/phone ARN)
// ─────────────────────────────────────────────────────────────────────────────
const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");
const { verifyToken, respond } = require("../utils/auth");

const db  = new DynamoDBClient({ region: "us-east-1" });
const ses = new SESClient({ region: "us-east-1" });
const sns = new SNSClient({ region: "us-east-1" });

const LOADS_TABLE  = process.env.LOADS_TABLE;
const FROM_EMAIL   = process.env.SES_FROM_EMAIL;
const AMPLIFY_URL  = process.env.AMPLIFY_BASE_URL || "";

// Set SNS_ENABLED=true in Lambda env vars once AWS grants production SMS access.
const SNS_ENABLED  = (process.env.SNS_ENABLED || "").toLowerCase() === "true";
// Optional: branded sender ID shown on the driver's phone (not supported in US/CA).
const SNS_SENDER_ID = process.env.SNS_SENDER_ID || "Routelo";

function buildLinks(event, token, id) {
  const base = AMPLIFY_URL || (function() {
    const d = event.requestContext && event.requestContext.domainName;
    const s = event.requestContext && event.requestContext.stage;
    return d ? ("https://" + d + (s && s !== "$default" ? "/" + s : "")) : "";
  })();

  const webLink = base
    + "/driver-tracking.html?token=" + encodeURIComponent(token)
    + "&loadId=" + encodeURIComponent(id);

  // Deep link opens the native Routelo app directly — no sign-in needed.
  // Falls back to web link for drivers who haven't installed the app.
  const appLink = "routelo://driver?token=" + encodeURIComponent(token)
    + "&loadId=" + encodeURIComponent(id);

  return { webLink, appLink };
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

// ── SNS SMS helpers ───────────────────────────────────────────────────────────
// These functions are no-ops when SNS_ENABLED is false so the handler works
// in sandbox mode without any SNS IAM permissions at all.

/**
 * Normalise a phone number to E.164 (+1XXXXXXXXXX).
 * Returns null if the number cannot be cleaned up.
 */
function toE164(phone) {
  if (!phone) return null;
  const digits = phone.replace(/[^\d]/g, "");
  if (digits.length === 10) return "+1" + digits;          // US local
  if (digits.length === 11 && digits[0] === "1") return "+" + digits; // 1XXXXXXXXXX
  if (digits.length > 7)  return "+" + digits;            // international — trust it
  return null;
}

/**
 * Send load-assignment SMS to the driver.
 * Gated behind SNS_ENABLED — safe to call unconditionally.
 */
async function sendDriverSMS(driverPhone, driverName, load, webLink, appLink) {
  if (!SNS_ENABLED) {
    console.log("SNS_ENABLED=false — SMS skipped (enable after AWS production SMS approval).");
    return;
  }
  const to = toE164(driverPhone);
  if (!to) {
    console.warn("sendDriverSMS: invalid or missing phone number:", driverPhone);
    return;
  }

  const pickupStr = load.pickupDate
    ? new Date(load.pickupDate).toLocaleDateString("en-US", {
        month: "short", day: "numeric", year: "numeric",
        hour: "2-digit", minute: "2-digit",
      })
    : "";

  const body =
    "Hi " + (driverName || "Driver") + ",\n\n" +
    "You have a new load from CMP Logistics.\n\n" +
    "LOAD #: " + (load.loadNumber || "--") + "\n" +
    "PICKUP: " + (load.pickupAddress || "--") + "\n" +
    "DELIVERY: " + (load.deliveryAddress || "--") + "\n" +
    (pickupStr ? "DATE: " + pickupStr + "\n" : "") +
    (load.notes ? "NOTES: " + load.notes + "\n" : "") +
    "\n👉 Tap to accept & start tracking:\n" + webLink;

  await sns.send(new PublishCommand({
    PhoneNumber: to,
    Message: body,
    MessageAttributes: {
      "AWS.SNS.SMS.SMSType": {
        DataType: "String",
        StringValue: "Transactional",   // higher delivery priority, not charged as promotional
      },
      // Sender ID is shown instead of a number on supported carriers/countries.
      // Has NO effect in the US — safe to include everywhere.
      "AWS.SNS.SMS.SenderID": {
        DataType: "String",
        StringValue: SNS_SENDER_ID,
      },
    },
  }));

  console.log("SNS SMS sent to", to, "for load", load.loadNumber);
}

/**
 * Send a short "please reopen" ping SMS to the driver.
 * Gated behind SNS_ENABLED — safe to call unconditionally.
 */
async function sendPingSMS(driverPhone, driverName, load, webLink, appLink) {
  if (!SNS_ENABLED) {
    console.log("SNS_ENABLED=false — ping SMS skipped.");
    return;
  }
  const to = toE164(driverPhone);
  if (!to) return;

  const body =
    "📍 " + (driverName || "Driver") + ", your dispatcher needs a location update for " +
    "Load " + (load.loadNumber || "--") + ".\n\n" +
    "Reopen the tracking app:\n" + webLink;

  await sns.send(new PublishCommand({
    PhoneNumber: to,
    Message: body,
    MessageAttributes: {
      "AWS.SNS.SMS.SMSType": { DataType: "String", StringValue: "Transactional" },
      "AWS.SNS.SMS.SenderID": { DataType: "String", StringValue: SNS_SENDER_ID },
    },
  }));

  console.log("SNS ping SMS sent to", to, "for load", load.loadNumber);
}

exports.handler = async (event) => {
  try {
    verifyToken(event);

    const loadId = event.pathParameters && event.pathParameters.id;
    if (!loadId) return respond(400, { error: "Load ID required" });

    const body = JSON.parse(event.body || "{}");
    const { dispatcherEmail, notifyCustomer = false, pingOnly = false } = body;
    if (!dispatcherEmail) return respond(400, { error: "dispatcherEmail required" });

    // 1. Fetch load
    const res = await db.send(new GetItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: loadId }),
    }));
    if (!res.Item) return respond(404, { error: "Load not found" });
    const load = unmarshall(res.Item);

    // 2. Build tracking links
    const { webLink, appLink } = buildLinks(event, load.trackingToken, load.id);
    const link = webLink; // web fallback used in emails

    // ── PING-ONLY path ──────────────────────────────────────────────────────
    // Dispatcher tapped "Ping Driver" — just send a short "please reopen" SMS
    // (and a brief email) without sending the full load assignment messages.
    if (pingOnly) {
      // Short email to driver (if email on file)
      if (load.assignedDriverEmail && FROM_EMAIL) {
        try {
          await ses.send(new SendEmailCommand({
            Source: FROM_EMAIL,
            Destination: { ToAddresses: [load.assignedDriverEmail] },
            Message: {
              Subject: { Data: "Action needed – CMP Logistics Load " + load.loadNumber },
              Body: {
                Html: {
                  Data:
                    "<p>Hi <strong>" + (load.assignedDriverName || "Driver") + "</strong>,</p>" +
                    "<p>Your dispatcher is requesting an updated location for Load <strong>" +
                    load.loadNumber + "</strong>. Please reopen the tracking app:</p>" +
                    "<p style='margin-top:16px;'>" +
                    "<a href='" + link + "' style='background:#FF9500;color:#fff;padding:14px 28px;border-radius:10px;text-decoration:none;font-weight:700;font-size:16px;'>Reopen Tracking App</a>" +
                    "</p>" +
                    "<p style='color:#888;font-size:12px;margin-top:20px;'>No app needed – works in any browser.</p>",
                },
              },
            },
          }));
        } catch (e) {
          console.warn("Ping email failed:", e.message);
        }
      }

      // Ping SMS (fires only when SNS_ENABLED=true)
      try {
        await sendPingSMS(load.assignedDriverPhone, load.assignedDriverName, load, webLink, appLink);
      } catch (e) {
        console.warn("Ping SMS failed:", e.message);
      }

      return respond(200, { success: true, driverLink: link });
    }
    // ────────────────────────────────────────────────────────────────────────

    // 3. Send email to driver (if email on file)
    try {
      await sendDriverEmail(load.assignedDriverEmail, load.assignedDriverName, load, link);
    } catch (e) {
      console.warn("Driver email failed:", e.message);
    }

    // 4. Send SMS to driver (fires only when SNS_ENABLED=true)
    try {
      await sendDriverSMS(load.assignedDriverPhone, load.assignedDriverName, load, webLink, appLink);
    } catch (e) {
      console.warn("Driver SMS failed:", e.message);
    }

    // 5. Email dispatcher confirmation with the driver link
    if (FROM_EMAIL) {
      try {
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [dispatcherEmail] },
          Message: {
            Subject: { Data: "Driver notified – Load " + load.loadNumber },
            Body: {
              Html: {
                Data:
                  "<p>The driver tracking link has been sent to <strong>" + (load.assignedDriverEmail || "driver") + "</strong>.</p>" +
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

    return respond(200, { success: true, driverLink: link });

  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("sendDriverLink error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
