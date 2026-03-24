// src/handlers/login.js
// POST /users/login
// Body: { email, password }
// Returns: { token, user }

const { DynamoDBClient, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const crypto = require("crypto");
const jwt = require("jsonwebtoken");

const db = new DynamoDBClient({});
const TABLE         = process.env.USERS_TABLE;
const PENDING_TABLE = process.env.PENDING_TABLE || "cmp-pending";
const JWT_SECRET    = process.env.JWT_SECRET;

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
    const { email, password } = body;

    if (!email || !password) {
      return respond(400, { error: "email and password are required." });
    }

    const trimmedEmail = email.toLowerCase().trim();

    // Check main users table first
    const result = await db.send(new GetItemCommand({
      TableName: TABLE,
      Key: marshall({ email: trimmedEmail }),
    }));

    if (!result.Item) {
      // Check pending table — give a more helpful error
      const pendingResult = await db.send(new GetItemCommand({
        TableName: PENDING_TABLE,
        Key: marshall({ email: trimmedEmail }),
      }));
      if (pendingResult.Item) {
        return respond(403, {
          error: "⏳ Your account is pending admin approval. You will receive an email once approved.",
          status: "pending",
        });
      }
      return respond(401, { error: "No account found for that email / password." });
    }

    const user = unmarshall(result.Item);

    if (user.passwordHash !== sha256(password)) {
      return respond(401, { error: "No account found for that email / password." });
    }

    // Check approval status
    if (user.status === "pending") {
      return respond(403, {
        error: "⏳ Your account is pending approval. You will receive an email once an admin approves your request.",
        status: "pending",
      });
    }
    if (user.status === "denied") {
      return respond(403, {
        error: "❌ Your account request was not approved. Contact your company admin for help.",
        status: "denied",
      });
    }

    // Issue JWT — includes tenantId and companyName for multi-tenant isolation
    const token = jwt.sign(
      {
        email:       user.email,
        role:        user.role,
        name:        user.name,
        tenantId:    user.tenantId    || null,
        companyName: user.companyName || null,
        plan:        user.plan        || null,
      },
      JWT_SECRET,
      { expiresIn: "30d" }
    );

    const { passwordHash, ...safeUser } = user;
    return respond(200, { token, user: safeUser });
  } catch (err) {
    console.error("login error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
