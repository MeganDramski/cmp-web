// src/handlers/registerCompany.js
// POST /companies/register
// Creates a new company (tenant) + admin user in one shot.
// Body: { companyName, adminName, adminEmail, password }
// Returns: { token, user, company }

const { DynamoDBClient, GetItemCommand, PutItemCommand } = require("@aws-sdk/client-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { marshall } = require("@aws-sdk/util-dynamodb");
const crypto = require("crypto");
const jwt    = require("jsonwebtoken");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const COMPANIES_TABLE = process.env.COMPANIES_TABLE;
const USERS_TABLE     = process.env.USERS_TABLE;
const JWT_SECRET      = process.env.JWT_SECRET;
const SES_FROM        = process.env.SES_FROM_EMAIL;

function sha256(str) {
  return crypto.createHash("sha256").update(str).digest("hex");
}

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

exports.handler = async (event) => {
  try {
    const body = JSON.parse(event.body || "{}");
    const { companyName, adminName, adminEmail, password } = body;

    if (!companyName || !adminName || !adminEmail || !password) {
      return respond(400, { error: "companyName, adminName, adminEmail and password are required." });
    }
    if (password.length < 8) {
      return respond(400, { error: "Password must be at least 8 characters." });
    }

    const email = adminEmail.toLowerCase().trim();

    // Check if email is already registered
    const existing = await db.send(new GetItemCommand({
      TableName: USERS_TABLE,
      Key: marshall({ email }),
    }));
    if (existing.Item) {
      return respond(409, { error: "An account with that email already exists." });
    }

    const tenantId  = crypto.randomUUID();
    const now       = new Date().toISOString();

    // ── Create company record ──────────────────────────────────────────────
    const company = {
      tenantId,
      companyName:  companyName.trim(),
      adminEmail:   email,
      plan:         "trial",      // free 14-day trial, upgrades via Stripe
      status:       "active",
      trialEndsAt:  new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString(),
      stripeCustomerId:      null,
      stripeSubscriptionId:  null,
      createdAt:    now,
    };

    await db.send(new PutItemCommand({
      TableName: COMPANIES_TABLE,
      Item: marshall(company, { removeUndefinedValues: true }),
    }));

    // ── Create admin user record ───────────────────────────────────────────
    const user = {
      email,
      name:         adminName.trim(),
      role:         "dispatcher",   // admin dispatchers use the dispatcher role
      tenantId,
      companyName:  companyName.trim(),
      plan:         "trial",
      passwordHash: sha256(password),
      status:       "active",       // no approval needed — they created the company
      createdAt:    now,
    };

    await db.send(new PutItemCommand({
      TableName: USERS_TABLE,
      Item: marshall(user, { removeUndefinedValues: true }),
    }));

    // ── Issue JWT ──────────────────────────────────────────────────────────
    const token = jwt.sign(
      {
        email,
        role:        "dispatcher",
        name:        adminName.trim(),
        tenantId,
        companyName: companyName.trim(),
        plan:        "trial",
      },
      JWT_SECRET,
      { expiresIn: "30d" }
    );

    // ── Send welcome email ─────────────────────────────────────────────────
    if (SES_FROM) {
      try {
        await ses.send(new SendEmailCommand({
          Source: SES_FROM,
          Destination: { ToAddresses: [email] },
          Message: {
            Subject: { Data: `Welcome to Routelo, ${companyName.trim()}!` },
            Body: {
              Html: {
                Data: `
                  <h2>Welcome aboard, ${adminName.trim()}!</h2>
                  <p>Your company <strong>${companyName.trim()}</strong> has been set up on Routelo.</p>
                  <p>You have a <strong>14-day free trial</strong>. After that, a subscription is required to continue.</p>
                  <p>Log in at your dispatcher portal to get started.</p>
                  <p>— The Routelo Team</p>
                `,
              },
            },
          },
        }));
      } catch (emailErr) {
        console.warn("Welcome email failed:", emailErr.message);
      }
    }

    const { passwordHash, ...safeUser } = user;
    return respond(201, { token, user: safeUser, company });
  } catch (err) {
    console.error("registerCompany error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
