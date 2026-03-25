// inboundSMS.js
// Receives driver SMS replies forwarded by Pinpoint → SNS → this Lambda
// Payload from Pinpoint two-way SMS looks like:
// {
//   "originationNumber": "+13475599151",   ← driver's phone
//   "destinationNumber": "+18446233665",   ← our Routelo number
//   "messageBody": "STOP / YES / on my way etc.",
//   "inboundMessageId": "...",
//   "messageKeyword": "STOP"
// }

const { DynamoDBClient, QueryCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");

const db  = new DynamoDBClient({ region: "us-east-1" });
const ses = new SESClient({ region: "us-east-1" });

const LOADS_TABLE = process.env.LOADS_TABLE;
const FROM_EMAIL  = process.env.SES_FROM_EMAIL;

exports.handler = async (event) => {
  console.log("Inbound SMS event:", JSON.stringify(event));

  for (const record of (event.Records || [])) {
    try {
      const msg = JSON.parse(record.Sns.Message);
      const driverPhone  = msg.originationNumber;  // driver replied from this number
      const messageBody  = (msg.messageBody || "").trim();
      const keyword      = (msg.messageKeyword || "").toUpperCase();

      console.log(`Reply from ${driverPhone}: "${messageBody}" keyword="${keyword}"`);

      // STOP is handled automatically by Pinpoint — just log it
      if (keyword === "STOP" || keyword === "UNSTOP" || keyword === "HELP") {
        console.log("Opt-out/help keyword handled by Pinpoint automatically.");
        continue;
      }

      // Find the load assigned to this driver phone
      const result = await db.send(new QueryCommand({
        TableName: LOADS_TABLE,
        IndexName: "assignedDriverPhone-index",
        KeyConditionExpression: "assignedDriverPhone = :p",
        ExpressionAttributeValues: marshall({ ":p": driverPhone }),
        Limit: 1,
        ScanIndexForward: false,
      }));

      const load = result.Items && result.Items.length > 0
        ? unmarshall(result.Items[0])
        : null;

      if (!load) {
        console.log("No load found for driver phone:", driverPhone);
        continue;
      }

      const dispatcherEmail = load.dispatcherEmail || load.createdBy;

      // Forward the reply to the dispatcher by email
      if (dispatcherEmail && FROM_EMAIL) {
        await ses.send(new SendEmailCommand({
          Source: FROM_EMAIL,
          Destination: { ToAddresses: [dispatcherEmail] },
          Message: {
            Subject: { Data: `💬 Driver reply – Load ${load.loadNumber}` },
            Body: {
              Html: {
                Data: `
                  <div style="font-family:-apple-system,sans-serif;max-width:520px;margin:32px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
                    <div style="background:#007AFF;padding:20px 24px;">
                      <div style="font-size:18px;font-weight:700;color:#fff;">💬 Driver Reply Received</div>
                      <div style="color:rgba(255,255,255,.8);font-size:13px;margin-top:4px;">Load ${load.loadNumber}</div>
                    </div>
                    <div style="padding:20px 24px;">
                      <table style="width:100%;font-size:14px;border-collapse:collapse;">
                        <tr><td style="color:#888;padding:6px 0;width:120px;">Driver</td><td style="font-weight:600;">${load.assignedDriverName || driverPhone}</td></tr>
                        <tr style="border-top:1px solid #f0f0f0;"><td style="color:#888;padding:6px 0;">Phone</td><td>${driverPhone}</td></tr>
                        <tr style="border-top:1px solid #f0f0f0;"><td style="color:#888;padding:6px 0;">Load #</td><td>${load.loadNumber}</td></tr>
                        <tr style="border-top:1px solid #f0f0f0;"><td style="color:#888;padding:6px 0;">Route</td><td>${load.pickupAddress} → ${load.deliveryAddress}</td></tr>
                      </table>
                      <div style="margin-top:16px;background:#f4f4f8;border-radius:10px;padding:14px;">
                        <div style="font-size:11px;color:#888;margin-bottom:6px;text-transform:uppercase;letter-spacing:.5px;">Message</div>
                        <div style="font-size:15px;font-weight:600;">"${messageBody}"</div>
                      </div>
                      <p style="font-size:11px;color:#aaa;margin-top:20px;text-align:center;">— Routelo</p>
                    </div>
                  </div>`,
              },
            },
          },
        }));
        console.log("Forwarded driver reply to dispatcher:", dispatcherEmail);
      }
    } catch (err) {
      console.error("Error processing inbound SMS record:", err);
    }
  }

  return { statusCode: 200 };
};
