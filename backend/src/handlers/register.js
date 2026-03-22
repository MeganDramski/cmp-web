// src/handlers/register.js
const { DynamoDBClient, GetItemCommand, PutItemCommand } = require("@aws-sdk/client-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const crypto = require("crypto");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const TABLE           = process.env.USERS_TABLE;
const PENDING_TABLE   = process.env.PENDING_TABLE || "cmp-pending";
const COMPANIES_TABLE = process.env.COMPANIES_TABLE;
const SES_FROM        = process.env.SES_FROM_EMAIL;
const API_BASE        = process.env.TRACKING_BASE_URL || "";
const AMPLIFY_BASE    = process.env.AMPLIFY_BASE_URL  || "";

const APPROVAL_ADMINS = (process.env.APPROVAL_ADMINS || "megandramski@gmail.com,dispatch@cmplogistics.ca")
  .split(",").map(s => s.trim()).filter(Boolean);

function sha256(str) {
  return crypto.createHash("sha256").update(str).digest("hex");
}

function makeApprovalToken(email, action) {
  const payload = email + "|" + action + "|" + Date.now();
  const hmac = crypto.createHmac("sha256", process.env.JWT_SECRET || "cmp-secret")
    .update(payload).digest("hex");
  return Buffer.from(payload + "|" + hmac).toString("base64url");
}

exports.handler = async (event) => {
  try {
    const body = JSON.parse(event.body || "{}");
    const { name, email, phone, role, password, tenantId } = body;

    if (!name || !email || !password || !role) {
      return respond(400, { error: "name, email, password and role are required." });
    }
    if (password.length < 6) {
      return respond(400, { error: "Password must be at least 6 characters." });
    }
    if (!["driver", "dispatcher"].includes(role)) {
      return respond(400, { error: "role must be driver or dispatcher." });
    }

    const trimmedEmail = email.toLowerCase().trim();

    const existing = await db.send(new GetItemCommand({
      TableName: TABLE,
      Key: marshall({ email: trimmedEmail }),
    }));
    if (existing.Item) {
      return respond(409, { error: "An account with that email already exists." });
    }

    const existingPending = await db.send(new GetItemCommand({
      TableName: PENDING_TABLE,
      Key: marshall({ email: trimmedEmail }),
    }));
    if (existingPending.Item) {
      return respond(409, { error: "A request for this email is already pending admin approval." });
    }

    // Look up company name if tenantId provided
    let companyName = null;
    if (tenantId && COMPANIES_TABLE) {
      try {
        const compResult = await db.send(new GetItemCommand({
          TableName: COMPANIES_TABLE,
          Key: marshall({ tenantId }),
        }));
        if (compResult.Item) {
          companyName = unmarshall(compResult.Item).companyName || null;
        } else {
          return respond(404, { error: "Company not found. Check your invite link." });
        }
      } catch (e) {
        console.warn("Could not look up company:", e.message);
      }
    }

    const item = {
      email:        trimmedEmail,
      name:         name.trim(),
      phone:        (phone || "").trim(),
      role,
      tenantId:     tenantId || null,
      companyName:  companyName,
      passwordHash: sha256(password),
      createdAt:    new Date().toISOString(),
    };

    await db.send(new PutItemCommand({
      TableName: PENDING_TABLE,
      Item:      marshall(item),
    }));

    const approveToken = makeApprovalToken(trimmedEmail, "approve");
    const denyToken    = makeApprovalToken(trimmedEmail, "deny");
    const approveUrl   = API_BASE + "/users/approve?token=" + approveToken;
    const denyUrl      = API_BASE + "/users/approve?token=" + denyToken;
    const portalUrl    = AMPLIFY_BASE || "https://main.d1j00v80wf0na9.amplifyapp.com";

    const textBody = "New sign-up request for CMP Logistics Tracking Portal.\n\n"
      + "Name:  " + item.name + "\n"
      + "Email: " + trimmedEmail + "\n"
      + "Phone: " + (item.phone || "-") + "\n"
      + "Role:  " + role + "\n"
      + "Time:  " + item.createdAt + "\n\n"
      + "APPROVE: " + approveUrl + "\n"
      + "DENY:    " + denyUrl + "\n\n"
      + "Portal: " + portalUrl;

    const htmlBody = "<div style='font-family:sans-serif;max-width:520px;background:#0f0f1a;color:#fff;border-radius:16px;overflow:hidden'>"
      + "<div style='background:#1c1c2e;padding:28px 32px;border-bottom:1px solid #2c2c3e'>"
      + "<h2 style='margin:0;font-size:20px'>New Sign-Up Request</h2>"
      + "<p style='margin:4px 0 0;color:#8e8ea0;font-size:13px'>CMP Logistics Tracking Portal</p>"
      + "</div><div style='padding:28px 32px'>"
      + "<p><strong>Name:</strong> " + item.name + "</p>"
      + "<p><strong>Email:</strong> " + trimmedEmail + "</p>"
      + "<p><strong>Phone:</strong> " + (item.phone || "-") + "</p>"
      + "<p><strong>Role:</strong> " + role + "</p>"
      + "<p><strong>Time:</strong> " + item.createdAt + "</p>"
      + "<div style='display:flex;gap:12px;margin-top:24px'>"
      + "<a href='" + approveUrl + "' style='flex:1;padding:14px;background:#34C759;color:#fff;text-decoration:none;border-radius:12px;font-weight:700;text-align:center'>Approve</a>"
      + "<a href='" + denyUrl + "' style='flex:1;padding:14px;background:#FF3B30;color:#fff;text-decoration:none;border-radius:12px;font-weight:700;text-align:center'>Deny</a>"
      + "</div></div></div>";

    await Promise.allSettled(
      APPROVAL_ADMINS.map(function(admin) {
        return ses.send(new SendEmailCommand({
          Source: SES_FROM,
          Destination: { ToAddresses: [admin] },
          Message: {
            Subject: { Data: "[CMP] New sign-up request - " + item.name + " (" + trimmedEmail + ")" },
            Body: {
              Text: { Data: textBody },
              Html: { Data: htmlBody },
            },
          },
        }));
      })
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
    statusCode: statusCode,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    body: JSON.stringify(body),
  };
}
