//endDriverLink.js – sends driver tracking link via email (SES)
const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { verifyToken, respond } = require("../utils/auth");

const db  = new DynamoDBClient({ region: "us-east-1" });
const ses = new SESClient({ region: "us-east-1" });

const LOADS_TABLE = process.env.LOADS_TABLE;
const FROM_EMAIL  = process.env.SES_FROM_EMAIL;
const AMPLIFY_URL = process.env.AMPLIFY_BASE_URL || "";

function buildLink(event, token, id, load) {
  const base = AMPLIFY_URL || (function() {
    const d = event.requestContext && event.requestContext.domainName;
    const s = event.requestContext && event.requestContext.stage;
    return d ? ("https://" + d + (s && s !== "$default" ? "/" + s : "")) : "";
  })();

  // Embed full load payload as ?d= so the driver page renders without an API call.
  // Unicode-safe btoa: encodeURIComponent → unescape → btoa (mirrors dispatcher frontend).
  let encoded = "";
  try {
    const payload = {
      id:                  load.id,
      loadNumber:          load.loadNumber          || "",
      description:         load.description         || "",
      pickupAddress:       load.pickupAddress       || "",
      deliveryAddress:     load.deliveryAddress     || "",
      pickupDate:          load.pickupDate          || "",
      deliveryDate:        load.deliveryDate        || "",
      weight:              load.weight              || 0,
      customerName:        load.customerName        || "",
      customerEmail:       load.customerEmail       || "",
      dispatcherEmail:     load.dispatcherEmail     || load.createdBy || "",
      notifyCustomer:      load.notifyCustomer      || false,
      notes:               load.notes               || "",
      assignedDriverName:  load.assignedDriverName  || "",
      assignedDriverEmail: load.assignedDriverEmail || "",
      assignedDriverPhone: load.assignedDriverPhone || "",
      // Always surface as Assigned so the driver sees Accept button
      status:              (load.status === "Pending" || !load.status) ? "Assigned" : load.status,
      trackingToken:       token,
    };
    encoded = Buffer.from(unescape(encodeURIComponent(JSON.stringify(payload))), "binary")
                    .toString("base64");
  } catch (e) {
    console.warn("buildLink encode error:", e.message);
  }

  return base
    + "/driver-tracking.html?token=" + encodeURIComponent(token)
    + "&loadId=" + encodeURIComponent(id)
    + (encoded ? "&d=" + encodeURIComponent(encoded) : "");
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
    const { dispatcherEmail, notifyCustomer = false, pingOnly = false } = body;
    if (!dispatcherEmail) return respond(400, { error: "dispatcherEmail required" });

    // 1. Fetch load
    const res = await db.send(new GetItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: loadId }),
    }));
    if (!res.Item) return respond(404, { error: "Load not found" });
    const load = unmarshall(res.Item);

    // 2. Build tracking link
    const link = buildLink(event, load.trackingToken, load.id, load);

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
      return respond(200, { success: true, driverLink: link });
    }
    // ────────────────────────────────────────────────────────────────────────

    // 3. Send email to driver (if email on file)
    try {
      await sendDriverEmail(load.assignedDriverEmail, load.assignedDriverName, load, link);
    } catch (e) {
      console.warn("Driver email failed:", e.message);
    }

    // 4. Email dispatcher confirmation with the driver link
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
