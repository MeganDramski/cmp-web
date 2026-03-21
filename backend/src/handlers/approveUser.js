// src/handlers/approveUser.js
// GET /users/approve?token=<base64url-token>
// Called when an admin clicks Approve or Deny in the email.
// Verifies the HMAC-signed token, updates the user's status in DynamoDB,
// sends a confirmation email to the applicant, and returns a styled HTML page.

const { DynamoDBClient, GetItemCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const crypto = require("crypto");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const TABLE        = process.env.USERS_TABLE;
const SES_FROM     = process.env.SES_FROM_EMAIL;
const AMPLIFY_BASE = process.env.AMPLIFY_BASE_URL || "https://main.d1j00v80wf0na9.amplifyapp.com";
const SECRET       = process.env.JWT_SECRET || "cmp-secret";

/** Verify token and extract { email, action } */
function parseToken(raw) {
  try {
    const decoded = Buffer.from(raw, "base64url").toString("utf8");
    const parts   = decoded.split("|");
    // parts: [email, action, timestamp, hmac]
    if (parts.length !== 4) return null;
    const [email, action, ts, hmac] = parts;
    const payload  = `${email}|${action}|${ts}`;
    const expected = crypto.createHmac("sha256", SECRET).update(payload).digest("hex");
    if (!crypto.timingSafeEqual(Buffer.from(hmac), Buffer.from(expected))) return null;
    return { email, action };
  } catch {
    return null;
  }
}

exports.handler = async (event) => {
  const raw = (event.queryStringParameters || {}).token || "";

  if (!raw) return html(400, "❌ Invalid Link", "No token provided. This link may be malformed.");

  const parsed = parseToken(raw);
  if (!parsed) return html(400, "❌ Invalid Link", "This link is invalid or has been tampered with.");

  const { email, action } = parsed;
  if (action !== "approve" && action !== "deny") {
    return html(400, "❌ Invalid Action", "Unknown action in this link.");
  }

  // Fetch existing user
  const existing = await db.send(new GetItemCommand({
    TableName: TABLE,
    Key: marshall({ email }),
  }));

  if (!existing.Item) {
    return html(404, "👤 User Not Found", `No sign-up request found for <strong>${email}</strong>.`);
  }

  const user = unmarshall(existing.Item);

  // Idempotency: already actioned
  if (user.status === "approved" && action === "approve") {
    return html(200, "✅ Already Approved", `<strong>${user.name}</strong> (${email}) was already approved and can sign in.`);
  }
  if (user.status === "denied" && action === "deny") {
    return html(200, "Already Denied", `<strong>${user.name}</strong> (${email}) was already denied.`);
  }

  const newStatus = action === "approve" ? "approved" : "denied";

  // Update status in DynamoDB
  await db.send(new UpdateItemCommand({
    TableName: TABLE,
    Key: marshall({ email }),
    UpdateExpression: "SET #s = :s, approvedAt = :t",
    ExpressionAttributeNames:  { "#s": "status" },
    ExpressionAttributeValues: marshall({ ":s": newStatus, ":t": new Date().toISOString() }),
  }));

  // Email the applicant
  try {
    if (action === "approve") {
      await ses.send(new SendEmailCommand({
        Source: SES_FROM,
        Destination: { ToAddresses: [email] },
        Message: {
          Subject: { Data: "✅ Your CMP Logistics account has been approved!" },
          Body: {
            Text: { Data: `Hi ${user.name},\n\nYour account request for the CMP Logistics Tracking Portal has been approved.\n\nYou can now sign in at:\n${AMPLIFY_BASE}\n\nWelcome aboard!\n— CMP Logistics` },
            Html: { Data: `
<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:480px;margin:0 auto;background:#0f0f1a;color:#fff;border-radius:16px;overflow:hidden">
  <div style="background:#1c1c2e;padding:28px 32px;border-bottom:1px solid #2c2c3e">
    <div style="font-size:28px;margin-bottom:6px">🚛</div>
    <h2 style="margin:0;font-size:20px;color:#34C759">Account Approved!</h2>
    <p style="margin:4px 0 0;color:#8e8ea0;font-size:13px">CMP Logistics Tracking Portal</p>
  </div>
  <div style="padding:28px 32px">
    <p style="font-size:15px;margin-bottom:20px">Hi <strong>${user.name}</strong>,<br><br>Your account has been approved. You can now sign in to the CMP Logistics Dispatcher Portal.</p>
    <a href="${AMPLIFY_BASE}" style="display:block;padding:14px 20px;background:#007AFF;color:#fff;text-decoration:none;border-radius:12px;font-size:15px;font-weight:700;text-align:center">Sign In Now →</a>
    <p style="margin-top:16px;font-size:12px;color:#8e8ea0;text-align:center">Welcome to CMP Logistics!</p>
  </div>
</div>`.trim() },
          },
        },
      }));
    } else {
      await ses.send(new SendEmailCommand({
        Source: SES_FROM,
        Destination: { ToAddresses: [email] },
        Message: {
          Subject: { Data: "Your CMP Logistics account request" },
          Body: {
            Text: { Data: `Hi ${user.name},\n\nUnfortunately your request for access to the CMP Logistics Tracking Portal has not been approved at this time.\n\nIf you believe this is a mistake, please contact dispatch@cmplogistics.ca.\n\n— CMP Logistics` },
            Html: { Data: `
<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:480px;margin:0 auto;background:#0f0f1a;color:#fff;border-radius:16px;overflow:hidden">
  <div style="background:#1c1c2e;padding:28px 32px;border-bottom:1px solid #2c2c3e">
    <div style="font-size:28px;margin-bottom:6px">🚛</div>
    <h2 style="margin:0;font-size:20px">Account Request Update</h2>
    <p style="margin:4px 0 0;color:#8e8ea0;font-size:13px">CMP Logistics Tracking Portal</p>
  </div>
  <div style="padding:28px 32px">
    <p style="font-size:15px;margin-bottom:16px">Hi <strong>${user.name}</strong>,<br><br>Your request for access to the CMP Logistics Dispatcher Portal has not been approved at this time.</p>
    <p style="font-size:13px;color:#8e8ea0">If you believe this is a mistake, please contact <a href="mailto:dispatch@cmplogistics.ca" style="color:#007AFF">dispatch@cmplogistics.ca</a>.</p>
  </div>
</div>`.trim() },
          },
        },
      }));
    }
  } catch (emailErr) {
    console.error("approveUser: failed to email applicant:", emailErr);
    // Don't fail the whole request — status was already updated
  }

  // Return a nice HTML confirmation page
  if (action === "approve") {
    return html(200,
      "✅ Account Approved",
      `<strong>${user.name}</strong> (${email}) has been approved.<br>They will receive a confirmation email and can now sign in at <a href="${AMPLIFY_BASE}" style="color:#007AFF">${AMPLIFY_BASE}</a>.`
    );
  } else {
    return html(200,
      "Account Denied",
      `<strong>${user.name}</strong> (${email}) has been denied. They will be notified by email.`
    );
  }
};

function html(status, title, body) {
  const icon   = title.startsWith("✅") ? "✅" : title.startsWith("❌") ? "❌" : "ℹ️";
  const color  = title.startsWith("✅") ? "#34C759" : title.startsWith("❌") ? "#FF3B30" : "#8e8ea0";
  return {
    statusCode: status,
    headers: { "Content-Type": "text/html; charset=utf-8" },
    body: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>CMP Logistics — ${title.replace(/[^\w\s]/g,"")}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#0f0f1a;color:#fff;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.card{width:100%;max-width:440px;background:#1c1c2e;border:1px solid #2c2c3e;border-radius:20px;padding:40px 32px;text-align:center}
.icon{font-size:52px;margin-bottom:16px}
h1{font-size:22px;font-weight:700;color:${color};margin-bottom:12px}
p{font-size:14px;color:#c0c0d0;line-height:1.7}
a{color:#007AFF}
.btn{display:inline-block;margin-top:24px;padding:12px 28px;background:#007AFF;color:#fff;text-decoration:none;border-radius:12px;font-size:15px;font-weight:700}
</style>
</head>
<body>
  <div class="card">
    <div class="icon">${icon}</div>
    <h1>${title}</h1>
    <p>${body}</p>
    <a class="btn" href="https://main.d1j00v80wf0na9.amplifyapp.com">Go to Portal</a>
  </div>
</body>
</html>`,
  };
}
