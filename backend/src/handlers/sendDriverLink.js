// sendDriverLink.js – sends driver tracking link via SES email + Pinpoint SMS V2
const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { PinpointSMSVoiceV2Client, SendTextMessageCommand } = require("@aws-sdk/client-pinpoint-sms-voice-v2");
const { verifyToken, respond } = require("../utils/auth");

const db       = new DynamoDBClient({ region: "us-east-1" });
const ses      = new SESClient({ region: "us-east-1" });
const pinpoint = new PinpointSMSVoiceV2Client({ region: "us-east-1" });

const LOADS_TABLE  = process.env.LOADS_TABLE;
const FROM_EMAIL   = process.env.SES_FROM_EMAIL;
const AMPLIFY_URL  = process.env.AMPLIFY_BASE_URL || "";

const SNS_ENABLED = (process.env.SNS_ENABLED || "").toLowerCase() === "true";

// ── Phone number routing ──────────────────────────────────────────────────────
// CA drivers → Canadian long code, US drivers → US toll-free
// Both numbers can send to their respective countries
const PHONE_CA = process.env.SMS_ORIGIN_CA || "+14504857586";  // CA long code
const PHONE_US = process.env.SMS_ORIGIN_US || "+18446233665";  // US toll-free (pending)
const PHONE_US_LC = process.env.SMS_ORIGIN_US_LC || "+13185318751"; // US long code - VOICE ONLY, needs SMS long code

/**
 * Normalise a phone number to E.164.
 * Returns null if invalid.
 */
function toE164(phone) {
  if (!phone) return null;
  const digits = phone.replace(/[^\d]/g, "");
  if (digits.length === 10) return "+1" + digits;
  if (digits.length === 11 && digits[0] === "1") return "+" + digits;
  if (digits.length > 7) return "+" + digits;
  return null;
}

/**
 * Pick the right origination number based on the destination.
 * Canadian numbers start with +1 followed by area codes:
 * 204,226,236,249,250,289,306,343,365,367,368,382,403,416,418,
 * 431,437,438,450,506,514,519,548,579,581,587,604,613,639,647,
 * 672,705,709,742,778,780,782,807,819,825,867,873,902,905
 */
const CA_AREA_CODES = new Set([
  204,226,236,249,250,289,306,343,365,367,368,382,
  403,416,418,431,437,438,450,506,514,519,548,579,
  581,587,604,613,639,647,672,705,709,742,778,780,
  782,807,819,825,867,873,902,905
]);

function pickOriginNumber(e164) {
  // TODO: restore proper routing once +18446233665 toll-free is approved
  // if (!e164 || !e164.startsWith("+1")) return PHONE_US;
  // const areaCode = parseInt(e164.slice(2, 5), 10);
  // return CA_AREA_CODES.has(areaCode) ? PHONE_CA : PHONE_US;
  return PHONE_CA; // temporary: CA long code for all SMS while US toll-free pending
}

function buildLinks(event, token, id) {
  const base = AMPLIFY_URL || (function() {
    const d = event.requestContext && event.requestContext.domainName;
    const s = event.requestContext && event.requestContext.stage;
    return d ? ("https://" + d + (s && s !== "$default" ? "/" + s : "")) : "";
  })();
  const webLink = base + "/driver-tracking.html?token=" + encodeURIComponent(token)
                + "&loadId=" + encodeURIComponent(id);
  const appLink = "routelo://driver?token=" + encodeURIComponent(token)
                + "&loadId=" + encodeURIComponent(id);
  return { webLink, appLink };
}

async function sendDriverEmail(driverEmail, driverName, load, link) {
  if (!driverEmail || !FROM_EMAIL) return;
  const company = load.companyName || "Routelo";
  await ses.send(new SendEmailCommand({
    Source: FROM_EMAIL,
    Destination: { ToAddresses: [driverEmail] },
    Message: {
      Subject: { Data: "Routelo – Load " + load.loadNumber + " assigned by " + company },
      Body: {
        Html: {
          Data:
            "<p>Hi <strong>" + (driverName || "Driver") + "</strong>,</p>" +
            "<p>You have a new load assigned via Routelo by <strong>" + company + "</strong>.</p>" +
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

// ── Pinpoint SMS helpers ──────────────────────────────────────────────────────

async function sendDriverSMS(driverPhone, driverName, load, webLink) {
  if (!SNS_ENABLED) {
    console.log("SNS_ENABLED=false — SMS skipped.");
    return;
  }
  const to = toE164(driverPhone);
  if (!to) { console.warn("sendDriverSMS: invalid phone:", driverPhone); return; }

  const origin  = pickOriginNumber(to);
  const company = load.companyName || "Routelo";
  const pickupStr = load.pickupDate
    ? new Date(load.pickupDate).toLocaleDateString("en-US", {
        month: "short", day: "numeric", year: "numeric",
        hour: "2-digit", minute: "2-digit",
      })
    : "";

  const message =
    "Hi " + (driverName || "Driver") + ",\n\n" +
    "You have a new load via Routelo.\n" +
    "Assigned by: " + company + "\n\n" +
    "LOAD #: " + (load.loadNumber || "--") + "\n" +
    "PICKUP: " + (load.pickupAddress || "--") + "\n" +
    "DELIVERY: " + (load.deliveryAddress || "--") + "\n" +
    (pickupStr ? "DATE: " + pickupStr + "\n" : "") +
    (load.notes ? "NOTES: " + load.notes + "\n" : "") +
    "\n👉 Tap to accept & start tracking:\n" + webLink;

  await pinpoint.send(new SendTextMessageCommand({
    DestinationPhoneNumber: to,
    OriginationIdentity: origin,
    MessageBody: message,
    MessageType: "TRANSACTIONAL",
  }));

  console.log("Pinpoint SMS sent to", to, "from", origin, "for load", load.loadNumber);
}

async function sendPingSMS(driverPhone, driverName, load, webLink) {
  if (!SNS_ENABLED) { console.log("SNS_ENABLED=false — ping SMS skipped."); return; }
  const to = toE164(driverPhone);
  if (!to) return;

  const origin = pickOriginNumber(to);
  const message =
    "📍 " + (driverName || "Driver") + ", your dispatcher needs a location update for " +
    "Load " + (load.loadNumber || "--") + ".\n\nReopen the tracking app:\n" + webLink;

  await pinpoint.send(new SendTextMessageCommand({
    DestinationPhoneNumber: to,
    OriginationIdentity: origin,
    MessageBody: message,
    MessageType: "TRANSACTIONAL",
  }));

  console.log("Pinpoint ping SMS sent to", to, "from", origin);
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
              Subject: { Data: "Action needed – Routelo Load " + load.loadNumber + " (" + (load.companyName || "Routelo") + ")" },
              Body: {
                Html: {
                  Data:
                    "<p>Hi <strong>" + (load.assignedDriverName || "Driver") + "</strong>,</p>" +
                    "<p>Your dispatcher at <strong>" + (load.companyName || "Routelo") + "</strong> is requesting an updated location for Load <strong>" +
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
                  "<p style='color:#888;font-size:12px;'>— Routelo</p>",
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
