// src/handlers/updateLoad.js
// PUT /loads/{id}  – full load update (edit all fields)
const { DynamoDBClient, UpdateItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");

const db = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    const loadId = event.pathParameters && event.pathParameters.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    // Tenant isolation: verify the load belongs to this company before updating
    if (user.tenantId) {
      const existing = await db.send(new GetItemCommand({
        TableName: TABLE,
        Key: marshall({ id: loadId }),
      }));
      if (existing.Item) {
        const existingLoad = unmarshall(existing.Item);
        if (existingLoad.tenantId && existingLoad.tenantId !== user.tenantId) {
          return respond(403, { error: "You do not have permission to update this load." });
        }
      }
    }

    const body = JSON.parse(event.body || "{}");

    const fields = [
      "loadNumber","description","weight","pickupAddress","deliveryAddress",
      "pickupDate","deliveryDate","status","assignedDriverId","assignedDriverName",
      "assignedDriverEmail","assignedDriverPhone","customerName","customerEmail",
      "customerPhone","notifyCustomer","notes","dispatcherEmail","companyName"
    ];

    const expParts  = ["updatedAt = :updatedAt"];
    const removeParts = [];
    const exprNames = {};
    const exprValues = { ":updatedAt": new Date().toISOString() };

    fields.forEach(function(f) {
      if (body[f] === undefined) return;
      const val = body[f];
      // Empty string or null means "clear this field" — use REMOVE so DynamoDB
      // doesn't throw a ValidationException on empty/null attribute values.
      if (val === null || val === "") {
        removeParts.push("#" + f);
        exprNames["#" + f] = f;
      } else {
        expParts.push("#" + f + " = :" + f);
        exprNames["#" + f] = f;
        exprValues[":" + f] = val;
      }
    });

    let updateExpression = "SET " + expParts.join(", ");
    if (removeParts.length > 0) {
      updateExpression += " REMOVE " + removeParts.join(", ");
    }

    await db.send(new UpdateItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
      UpdateExpression: updateExpression,
      ExpressionAttributeNames: Object.keys(exprNames).length ? exprNames : undefined,
      ExpressionAttributeValues: marshall(exprValues, { removeUndefinedValues: true }),
    }));

    const result = await db.send(new GetItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
    }));

    return respond(200, result.Item ? unmarshall(result.Item) : Object.assign({ id: loadId }, body));
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("updateLoad error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
