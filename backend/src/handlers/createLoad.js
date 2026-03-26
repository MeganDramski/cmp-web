// src/handlers/createLoad.js
// POST /loads
// Requires: Authorization: Bearer <token>  (dispatcher only)
// Body: Load object (see Models.swift)

const { DynamoDBClient, PutItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall } = require("@aws-sdk/util-dynamodb");
const { verifyToken, respond } = require("../utils/auth");
const crypto = require("crypto");

const db = new DynamoDBClient({});
const TABLE = process.env.LOADS_TABLE;

exports.handler = async (event) => {
  try {
    const user = verifyToken(event);
    if (user.role !== "dispatcher") {
      return respond(403, { error: "Only dispatchers can create loads." });
    }

    const body = JSON.parse(event.body || "{}");
    const required = ["pickupAddress", "deliveryAddress", "customerName"];
    for (const field of required) {
      if (!body[field]) return respond(400, { error: `${field} is required.` });
    }

    const load = {
      id:                  body.id            || crypto.randomUUID(),
      tenantId:            user.tenantId      || null,
      loadNumber:          body.loadNumber,
      description:         body.description,
      weight:              body.weight         || 0,
      pickupAddress:       body.pickupAddress,
      deliveryAddress:     body.deliveryAddress,
      pickupDate:          body.pickupDate     || new Date().toISOString(),
      deliveryDate:        body.deliveryDate   || new Date(Date.now() + 86400000).toISOString(),
      status:              body.status         || "Pending",
      assignedDriverId:    body.assignedDriverId    || null,
      assignedDriverName:  body.assignedDriverName  || null,
      assignedDriverEmail: body.assignedDriverEmail || null,
      assignedDriverPhone: body.assignedDriverPhone || null,
      trackingToken:       body.trackingToken  || crypto.randomUUID(),
      customerName:        body.customerName,
      customerEmail:       body.customerEmail  || "",
      customerPhone:       body.customerPhone  || "",
      notes:               body.notes          || "",
      dispatcherEmail:     body.dispatcherEmail || user.email,
      companyName:         user.companyName    || body.companyName || null,
      notifyCustomer:      body.notifyCustomer  || false,
      createdAt:           new Date().toISOString(),
      createdBy:           user.email,
    };

    await db.send(new PutItemCommand({
      TableName: TABLE,
      Item:      marshall(load, { removeUndefinedValues: true }),
    }));

    return respond(201, load);
  } catch (err) {
    if (err.statusCode) return respond(err.statusCode, { error: err.message });
    console.error("createLoad error:", err);
    return respond(500, { error: "Internal server error." });
  }
};
