// src/handlers/acceptLoad.js
// POST /loads/{id}/accept
//
// Driver calls this when they tap "Accept Load".
// 1. Updates load status to "Accepted" in DynamoDB
// 2. Emails the dispatcher a confirmation

const { DynamoDBClient, UpdateItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");
const { verifyToken, respond } = require("../utils/auth");

const db  = new DynamoDBClient({});
const ses = new SESClient({});

const TABLE      = process.env.LOADS_TABLE;
const FROM_EMAIL = process.env.SES_FROM_EMAIL;

exports.handler = async (event) => {
  try {
    verifyToken(event);

    const loadId = event.pathParameters?.id;
    if (!loadId) return respond(400, { error: "Load ID is required." });

    const body = JSON.parse(event.body || "{}");
    const driverName   = body.driverName   || "Your driver";
    const loadNumber   = body.loadNumber   || loadId;

    const now = new Date().toISOString();

    // 1. Update DynamoDB status → Accepted
    await db.send(new UpdateItemCommand({
      TableName: TABLE,
      Key: marshall({ id: loadId }),
      UpdateExpression: "SET #s = :s, updatedAt = :t",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: marshall({ ":s": "Accepted", ":t": now }),
    }));

    // 2. Fetch full load to get dispatcher email
    if (FROM_EMAIL) {
      try {
        const result = await db.send(new GetItemCommand({
          TableName: TABLE,
          Key: marshall({ id: loadId }),
        }));
        const load = result.Item ? unmarshall(result.Item) : null;
        const dispatcherEmail = load?.dispatcherEmail || load?.createdBy || body.dispatcherEmail;

        if (dispatcherEmail) {
          const acceptedTime = new Date(now).toLocaleString("en-US", {
            month: "short", day: "numeric", year: "numeric",
            hour: "numeric", minute: "2-digit", timeZoneName: "short",
          });

          await ses.send(new SendEmailCommand({
            Source: FROM_EMAIL,
            Destination: { ToAddresses: [dispatcherEmail] },
            Message: {
              Subject: { Data: `✅ Load ${loadNumber} Accepted by ${driverName}` },
              Body: {
                Html: {
                  Data: `
                    <p>Hi,</p>
                    <p><strong>${driverName}</strong> has accepted load <strong>${loadNumber}</strong>.</p>
                    <p>Accepted at: ${acceptedTime}</p>
                    <p>The driver is ready and will begin tracking at pickup time.</p>
                    <br/>
                    <p style="color:#888;font-size:12px;">CMP Tracking · Automated Notification</p>
                  `,
                },
              },
            },
          }));
        }
      } catch (emailErr) {
        // Don't fail the whole request if email fails
        console.warn("⚠️ Accept load email error:", emailErr.message);
      }
    }

    return respond(200, { message: "Load accepted.", loadId, status: "Accepted" });
  } catch (err) {
    console.error("acceptLoad error:", err);
    return respond(err.message === "Unauthorized" ? 401 : 500, { error: err.message });
  }
};
