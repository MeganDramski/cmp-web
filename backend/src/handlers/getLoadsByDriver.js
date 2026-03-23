// src/handlers/getLoadsByDriver.js
// GET /loads/by-driver?phone=...&name=...&email=...
// PUBLIC endpoint – no auth required.
// Returns active loads assigned to a driver by phone / email / name.

const { DynamoDBClient, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");

const db    = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "Content-Type,Authorization",
  "Access-Control-Allow-Methods": "GET,OPTIONS",
};

function respond(statusCode, body) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json", ...CORS },
    body: JSON.stringify(body),
  };
}

function digitsOnly(str) {
  return (str || "").replace(/\D/g, "");
}

exports.handler = async (event) => {
  // Handle CORS preflight
  if (event.requestContext?.http?.method === "OPTIONS") {
    return { statusCode: 200, headers: CORS, body: "" };
  }

  try {
    const qs    = event.queryStringParameters || {};
    const phone = digitsOnly(qs.phone || "");
    const name  = (qs.name  || "").trim().toLowerCase();
    const email = (qs.email || "").trim().toLowerCase();

    if (!phone && !name && !email) {
      return respond(400, { error: "At least one of phone, name, or email is required." });
    }

    const result   = await db.send(new ScanCommand({ TableName: TABLE }));
    const allLoads = (result.Items || []).map(unmarshall);

    const activeStatuses = new Set(["Assigned", "Accepted", "In Transit"]);

    const matched = allLoads.filter(load => {
      if (!activeStatuses.has(load.status)) return false;

      if (phone) {
        if (digitsOnly(load.assignedDriverPhone) === phone) return true;
        if (digitsOnly(load.assignedDriverId)    === phone) return true;
      }
      if (email && load.assignedDriverEmail &&
          load.assignedDriverEmail.trim().toLowerCase() === email) return true;
      if (name  && load.assignedDriverName  &&
          load.assignedDriverName.trim().toLowerCase()  === name)  return true;

      return false;
    });

    matched.sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));
    return respond(200, matched);

  } catch (err) {
    console.error("getLoadsByDriver error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
