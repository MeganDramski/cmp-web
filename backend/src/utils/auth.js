// src/utils/auth.js
// Shared JWT verification middleware helper

const jwt = require("jsonwebtoken");
const JWT_SECRET = process.env.JWT_SECRET;

/**
 * Verifies the Authorization: Bearer <token> header.
 * Returns the decoded payload or throws an error string.
 */
function verifyToken(event) {
  const authHeader = event.headers?.authorization || event.headers?.Authorization || "";
  if (!authHeader.startsWith("Bearer ")) {
    throw { statusCode: 401, message: "Missing or invalid Authorization header." };
  }
  const token = authHeader.slice(7);
  try {
    return jwt.verify(token, JWT_SECRET);
  } catch (e) {
    throw { statusCode: 401, message: "Token is invalid or expired. Please log in again." };
  }
}

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

module.exports = { verifyToken, respond };
