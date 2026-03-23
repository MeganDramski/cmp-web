#!/usr/bin/env node
/**
 * stamp-tenant-ids.js
 * 
 * One-time migration: stamps tenantId (and companyName) onto all existing
 * loads and users that were created before multi-tenant support was added.
 * 
 * Run with:
 *   AWS_PROFILE=your-profile node stamp-tenant-ids.js
 * 
 * Required env vars (or set them inline below):
 *   AWS_REGION        – e.g. us-east-1
 *   ADMIN_EMAIL       – email of the dispatcher who "owns" the legacy loads
 *   USERS_TABLE       – DynamoDB table name (default: cmp-users)
 *   LOADS_TABLE       – DynamoDB table name (default: cmp-loads)
 */

const { DynamoDBClient, ScanCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");

const REGION      = process.env.AWS_REGION      || "us-east-1";
const ADMIN_EMAIL = process.env.ADMIN_EMAIL      || ""; // set this!
const USERS_TABLE = process.env.USERS_TABLE      || "cmp-users";
const LOADS_TABLE = process.env.LOADS_TABLE      || "cmp-loads";

const db = new DynamoDBClient({ region: REGION });

async function main() {
  if (!ADMIN_EMAIL) {
    console.error("❌ Set ADMIN_EMAIL to the email of the dispatcher who owns the legacy data.");
    console.error("   e.g.  ADMIN_EMAIL=megandramski@gmail.com node stamp-tenant-ids.js");
    process.exit(1);
  }

  // 1. Look up the admin user to get their tenantId
  console.log(`\n🔍 Looking up admin user: ${ADMIN_EMAIL}`);
  const userResult = await db.send(new ScanCommand({
    TableName: USERS_TABLE,
    FilterExpression: "email = :e",
    ExpressionAttributeValues: { ":e": { S: ADMIN_EMAIL } },
  }));

  const users = (userResult.Items || []).map(unmarshall);
  const adminUser = users[0];

  if (!adminUser) {
    console.error(`❌ No user found with email: ${ADMIN_EMAIL}`);
    process.exit(1);
  }

  if (!adminUser.tenantId) {
    console.error(`❌ User ${ADMIN_EMAIL} has no tenantId. They may need to re-register as a company.`);
    process.exit(1);
  }

  const { tenantId, companyName } = adminUser;
  console.log(`✅ Found user: ${adminUser.name}`);
  console.log(`   tenantId:    ${tenantId}`);
  console.log(`   companyName: ${companyName || "(none)"}`);

  // 2. Stamp all loads that have no tenantId
  console.log(`\n📦 Scanning loads table for records missing tenantId...`);
  const loadsResult = await db.send(new ScanCommand({
    TableName: LOADS_TABLE,
    FilterExpression: "attribute_not_exists(tenantId)",
  }));

  const orphanLoads = (loadsResult.Items || []).map(unmarshall);
  console.log(`   Found ${orphanLoads.length} loads without tenantId.`);

  let loadCount = 0;
  for (const load of orphanLoads) {
    await db.send(new UpdateItemCommand({
      TableName: LOADS_TABLE,
      Key: marshall({ id: load.id }),
      UpdateExpression: "SET tenantId = :tid",
      ConditionExpression: "attribute_not_exists(tenantId)",
      ExpressionAttributeValues: marshall({ ":tid": tenantId }),
    }));
    loadCount++;
    process.stdout.write(`\r   Stamped ${loadCount}/${orphanLoads.length} loads...`);
  }
  console.log(`\n✅ Stamped ${loadCount} loads with tenantId: ${tenantId}`);

  // 3. Stamp all users that have no tenantId (drivers registered before multi-tenant)
  console.log(`\n👤 Scanning users table for records missing tenantId...`);
  const usersResult = await db.send(new ScanCommand({
    TableName: USERS_TABLE,
    FilterExpression: "attribute_not_exists(tenantId)",
  }));

  const orphanUsers = (usersResult.Items || []).map(unmarshall);
  console.log(`   Found ${orphanUsers.length} users without tenantId.`);

  let userCount = 0;
  for (const user of orphanUsers) {
    await db.send(new UpdateItemCommand({
      TableName: USERS_TABLE,
      Key: marshall({ email: user.email }),
      UpdateExpression: "SET tenantId = :tid, companyName = :cn",
      ConditionExpression: "attribute_not_exists(tenantId)",
      ExpressionAttributeValues: marshall({ ":tid": tenantId, ":cn": companyName || "" }),
    }));
    userCount++;
    process.stdout.write(`\r   Stamped ${userCount}/${orphanUsers.length} users...`);
  }
  console.log(`\n✅ Stamped ${userCount} users with tenantId: ${tenantId}`);

  console.log(`\n🎉 Migration complete!`);
  console.log(`   All existing loads and users now belong to: ${companyName || tenantId}`);
  console.log(`   Sign out and back in to get a fresh session token.\n`);
}

main().catch(err => {
  console.error("❌ Migration failed:", err.message);
  process.exit(1);
});
