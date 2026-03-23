// src/handlers/getLoadsByDriver.js
// GET /loads/by-driver?phone=13475599151
// PUBLIC endpoint – no auth required.
// Returns active loads assigned to a driver by their phone number.
// Used by the iOS driver app which may not have a valid dispatcher JWT.

const { DynamoDBClient, ScanCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");
const { respond } = require("../utils/auth");

const db    = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

// Strip everything except digits for a loose phone comparison
function digitsOnly(str) {
  return (str || "").replace(/\D/g, "");
}

exports.handler = async (event) => {
  try {
    const phone = digitsOnly(event.queryStringParameters?.phone || "");
    const name  = (event.queryStringParameters?.name || "").trim().toLowerCase();
    const email = (event.queryStringParameters?.email || "").trim().toLowerCase();

    if (!phone && !name && !email) {
      return respond(400, { error: "At least one of phone, name, or email is required." });
    }

    // Full scan — cmp-loads table is small (hundreds of rows max)
    const result = await db.send(new ScanCommand({ TableName: TABLE }));
    const allLoads = (result.Items || []).map(unmarshall);

    const activeStatuses = new Set(["Assigned", "Accepted", "In Transit"]);

    const matched = allLoads.filter(load => {
      if (!activeStatuses.has(load.status)) return false;

      // Phone match: assignedDriverPhone or assignedDriverId
      if (phone) {
        const loadPhone = digitsOnly(load.assignedDriverPhone);
        const loadId    = digitsOnly(load.assignedDriverId);
        if (loadPhone && loadPhone === phone) return true;
        if (loadId    && loadId    === phone) return true;
      }

      // Email match
      if (email && load.assignedDriverEmail) {
        if (load.assignedDriverEmail.trim().toLowerCase() === email) return true;
      }

      // Name match (last resort)
      if (name && load.assignedDriverName) {
        if (load.assignedDriverName.trim().toLowerCase() === name) return true;
      }

      return false;
    });

    // Sort newest first
    matched.sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));

    return respond(200, matched);
  } catch (err) {
    console.error("getLoadsByDriver error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
