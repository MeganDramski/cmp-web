// src/handlers/register.js
// POST /users/register
// Body: { name, email, phone, role, password }
// Saves request to cmp-pending table ONLY. User is NOT created in cmp-users
// until an admin clicks Approve. Emails admins with Approve / Deny links.

const { DynamoDBClient, GetItemCommand, PutItemCommand } = require("@aws-sdk/client-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { marshall } = require("@aws-sdk/util-dynamodb");
const crypto = require("crypto");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const TABLE          = process.env.USERS_TABLE;          // cmp-users  (read-only here — just for duplicate check)
const PENDING_TABLE  = process.env.PENDING_TABLE || "cmp-pending"; // cmp-pending (write here)
const SES_FROM       = process.env.SES_FROM_EMAIL;
const API_BASE       = process.env.TRACKING_BASE_URL || "";
const AMPLIFY_BASE   = process.env.AMPLIFY_BASE_URL  || "";

// Admins who receive approval emails
const APPROVAL_ADMINS = (process.env.APPROVAL_ADMINS || "megandramski@gmail.com,dispatch@cmplogistics.ca")
  .split(",").map(s => s.trim()).filter(Boolean);

function sha256(str) {
  return crypto.createHash("sha256").update(str).digest("hex");
}

/** Generate a signed approval token: base64(email|action|hmac) */
function makeApprovalToken(email, action) {
  const payload = `${email}|${action}|${Date.now()}`;
  const hmac = crypto.createHmac("sha256", process.env.JWT_SECRET || "cmp-secret")
    .update(payload).digest("hex");
  return Buffer.from(`${payload}|${hmac}`).toString("base64url");
}

exports.handler = async (event) => {
  try {
    const body = JSON.parse(event.body || "{}");
    const { name, email, phone, role, password } = body;

    if (!name || !email || !password || !role) {
      return respond(400, { error: "name, email, password and role are required." });
    }
    if (password.length < 6) {
      return respond(400, { error: "Password must be at least 6 characters." });
    }
    const validRoles = ["driver", "dispatcher"];
    if (!validRoles.includes(role)) {
      return respond(400, { error: "role must be 'driver' or 'dispatcher'." });
    }

    const trimmedEmail = email.toLowerCase().trim();

    // Check duplicate in cmp-users (already approved account)
    const existing = await db.send(new GetItemCommand({
      TableName: TABLE,
      Key: marshall({ email: trimmedEmail }),
    }));
    if (existing.Item) {
      return respond(409, { error: "An account with that email already exists." });
    }

    // Check duplicate in cmp-pending (already submitted, awaiting approval)
    const existingPending = await db.send(new GetItemCommand({
      TableName: PENDING_TABLE,
      Key: marshall({ email: trimmedEmail }),
    }));
    if (existingPending.Item) {
      return respond(409, { error: "A request for this email is already pending admin approval." });
    }

    // Save to cmp-pending ONLY — NOT to cmp-users
    // User will only be moved to cmp-users when an admin approves
    const item = {
      email:        trimmedEmail,
      name:         name.trim(),
      phone:        (phone || "").trim(),
      role,
      passwordHash: sha256(password),
      createdAt:    new Date().toISOString(),
    };

    await db.send(new PutItemCommand({
      TableName: PENDING_TABLE,
      Item:      marshall(item),
    }));

    // Build approve / deny links
    const approveToken = makeApprovalToken(trimmedEmail, "approve");
    const denyToken    = makeApprovalToken(trimmedEmail, "deny");
    const approveUrl   = `${API_BASE}/users/approve?token=${approveToken}`;
    const denyUrl      = `${API_BASE}/users/approve?token=${denyToken}`;
    const portalUrl    = AMPLIFY_BASE || "https://main.d1j00v80wf0na9.amplifyapp.com";

    const emailBody = `
New dispatcher sign-up request for CMP Logistics Tracking Portal.

Name:  ${item.name}
Email: ${trimmedEmail}
Phone: ${item.phone || "—"}
Role:  ${role}
Time:  ${item.createdAt}

──────────────────────────────────────
✅ APPROVE — click to grant access:
${approveUrl}

❌ DENY — click to reject:
${denyUrl}
──────────────────────────────────────

After approving, the user can sign in at:
${portalUrl}
`.trim();

    const htmlBody = `
<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:520px;margin:0 auto;background:#0f0f1a;color:#fff;border-radius:16px;overflow:hidden">
  <div style="background:#1c1c2e;padding:28px 32px;border-bottom:1px solid #2c2c3e">
    <div style="font-size:28px;margin-bottom:6px">🚛</div>
    <h2 style="margin:0;font-size:20px">New Sign-Up Request</h2>
    <p style="margin:4px 0 0;color:#8e8ea0;font-size:13px">CMP Logistics Tracking Portal</p>
  </div>
  <div style="padding:28px 32px">
    <table style="width:100%;border-collapse:collapse;font-size:14px;margin-bottom:24px">
      <tr><td style="color:#8e8ea0;padding:5px 0;width:80px">Name</td><td style="color:#fff;font-weight:600">${item.name}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Email</td><td style="color:#fff">${trimmedEmail}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Phone</td><td style="color:#fff">${item.phone || "—"}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Role</td><td style="color:#fff;text-transform:capitalize">${role}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Time</td><td style="color:#fff">${new Date(item.createdAt).toLocaleString("en-CA",{timeZone:"America/Toronto"})}</td></tr>
    </table>
    <div style="display:flex;gap:12px;flex-wrap:wrap">
      <a href="${approveUrl}" style="flex:1;min-width:140px;display:block;padding:14px 20px;background:#34C759;color:#fff;text-decoration:none;border-radius:12px;font-size:15px;font-weight:700;text-align:center">✅ Approve</a>
      <a href="${denyUrl}"    style="flex:1;min-width:140px;display:block;padding:14px 20px;background:#FF3B30;color:#fff;text-decoration:none;border-radius:12px;font-size:15px;font-weight:700;text-align:center">❌ Deny</a>
    </div>
    <p style="margin-top:20px;font-size:12px;color:#8e8ea0;text-align:center">These links are single-use. You can only approve or deny once per request.</p>
  </div>
</div>`.trim();

    // Send email to each admin
    await Promise.allSettled(
      APPROVAL_ADMINS.map(admin =>
        ses.send(new SendEmailCommand({
          Source: SES_FROM,
          Destination: { ToAddresses: [admin] },
          Message: {
            Subject: { Data: `[CMP] New sign-up request — ${item.name} (${trimmedEmail})` },
            Body: {
              Text: { Data: emailBody },
              Html: { Data: htmlBody },
            },
          },
        }))
      )
    );

    return respond(201, {
      message: "Your request has been submitted. You will receive an email once an admin approves your account.",
      status: "pending",
    });
  } catch (err) {
    console.error("register error:", err);
    return respond(500, { error: "Internal server error." });
  }
};

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*
      createdAt:    new Date().toISOString(),
    };

    await db.send(new PutItemCommand({
      TableName: TABLE,
      Item:      marshall(item),
    }));

    // Build approve / deny links
    const approveToken = makeApprovalToken(trimmedEmail, "approve");
    const denyToken    = makeApprovalToken(trimmedEmail, "deny");
    const approveUrl   = `${API_BASE}/users/approve?token=${approveToken}`;
    const denyUrl      = `${API_BASE}/users/approve?token=${denyToken}`;
    const portalUrl    = AMPLIFY_BASE || "https://main.d1j00v80wf0na9.amplifyapp.com";

    const emailBody = `
New dispatcher sign-up request for CMP Logistics Tracking Portal.

Name:  ${item.name}
Email: ${trimmedEmail}
Phone: ${item.phone || "—"}
Role:  ${role}
Time:  ${item.createdAt}

──────────────────────────────────────
✅ APPROVE — click to grant access:
${approveUrl}

❌ DENY — click to reject:
${denyUrl}
──────────────────────────────────────

After approving, the user can sign in at:
${portalUrl}
`.trim();

    const htmlBody = `
<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:520px;margin:0 auto;background:#0f0f1a;color:#fff;border-radius:16px;overflow:hidden">
  <div style="background:#1c1c2e;padding:28px 32px;border-bottom:1px solid #2c2c3e">
    <div style="font-size:28px;margin-bottom:6px">🚛</div>
    <h2 style="margin:0;font-size:20px">New Sign-Up Request</h2>
    <p style="margin:4px 0 0;color:#8e8ea0;font-size:13px">CMP Logistics Tracking Portal</p>
  </div>
  <div style="padding:28px 32px">
    <table style="width:100%;border-collapse:collapse;font-size:14px;margin-bottom:24px">
      <tr><td style="color:#8e8ea0;padding:5px 0;width:80px">Name</td><td style="color:#fff;font-weight:600">${item.name}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Email</td><td style="color:#fff">${trimmedEmail}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Phone</td><td style="color:#fff">${item.phone || "—"}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Role</td><td style="color:#fff;text-transform:capitalize">${role}</td></tr>
      <tr><td style="color:#8e8ea0;padding:5px 0">Time</td><td style="color:#fff">${new Date(item.createdAt).toLocaleString("en-CA",{timeZone:"America/Toronto"})}</td></tr>
    </table>
    <div style="display:flex;gap:12px;flex-wrap:wrap">
      <a href="${approveUrl}" style="flex:1;min-width:140px;display:block;padding:14px 20px;background:#34C759;color:#fff;text-decoration:none;border-radius:12px;font-size:15px;font-weight:700;text-align:center">✅ Approve</a>
      <a href="${denyUrl}"    style="flex:1;min-width:140px;display:block;padding:14px 20px;background:#FF3B30;color:#fff;text-decoration:none;border-radius:12px;font-size:15px;font-weight:700;text-align:center">❌ Deny</a>
    </div>
    <p style="margin-top:20px;font-size:12px;color:#8e8ea0;text-align:center">These links are single-use. You can only approve or deny once per request.</p>
  </div>
</div>`.trim();

    // Send email to each admin
    await Promise.allSettled(
      APPROVAL_ADMINS.map(admin =>
        ses.send(new SendEmailCommand({
          Source: SES_FROM,
          Destination: { ToAddresses: [admin] },
          Message: {
            Subject: { Data: `[CMP] New sign-up request — ${item.name} (${trimmedEmail})` },
            Body: {
              Text: { Data: emailBody },
              Html: { Data: htmlBody },
            },
          },
        }))
      )
    );

    return respond(201, {
      message: "Your request has been submitted. You will receive an email once an admin approves your account.",
      status: "pending",
    });
  } catch (err) {
    console.error("register error:", err);
    return respond(500, { error: "Internal server error." });
  }
};

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    body: JSON.stringify(body),
  };
}
