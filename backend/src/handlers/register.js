// src/handlers/register.js
// POST /users/register
// Body: { name, email, phone, role, password }

const { DynamoDBClient, GetItemCommand, PutItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const crypto = require("crypto");

const db = new DynamoDBClient({});
const TABLE = process.env.USERS_TABLE;

function sha256(str) {
  return crypto.createHash("sha256").update(str).digest("hex");
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

    // Check duplicate
    const existing = await db.send(new GetItemCommand({
      TableName: TABLE,
      Key: marshall({ email: trimmedEmail }),
    }));
    if (existing.Item) {
      return respond(409, { error: "An account with that email already exists." });
    }

    const item = {
      email:        trimmedEmail,
      name:         name.trim(),
      phone:        (phone || "").trim(),
      role,
      passwordHash: sha256(password),
      createdAt:    new Date().toISOString(),
    };

    await db.send(new PutItemCommand({
      TableName: TABLE,
      Item:      marshall(item),
    }));

    // Return user without passwordHash
    const { passwordHash, ...safeUser } = item;
    return respond(201, { user: safeUser });
  } catch (err) {
    console.error("register error:", err);
    return respond(500, { error: "Internal server error." });
  }
};

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}
