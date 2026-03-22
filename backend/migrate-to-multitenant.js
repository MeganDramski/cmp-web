https://github.com/MeganDramski/multi-tenant-tackingapp.git#!/usr/bin/env node
// migrate-to-multitenant.js
// ─────────────────────────────────────────────────────────────────────────────
// One-time migration script: stamps all existing CMP loads and users with the
// seed tenantId for CMP Logistics (the original single-tenant company), and
// creates the corresponding company record in cmp-companies.
//
// Usage:
//   AWS_REGION=us-east-1 node migrate-to-multitenant.js
//
// The script is idempotent — it skips items that already have a tenantId.
// ─────────────────────────────────────────────────────────────────────────────

const { DynamoDBClient, ScanCommand, UpdateItemCommand, PutItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");

const REGION         = process.env.AWS_REGION || "us-east-1";
const SEED_TENANT_ID = process.env.SEED_TENANT_ID || "cmp-logistics-legacy-001";
const COMPANY_NAME   = process.env.COMPANY_NAME   || "CMP Logistics";
const ADMIN_EMAIL    = process.env.ADMIN_EMAIL     || "megandramski@gmail.com";

const LOADS_TABLE    = process.env.LOADS_TABLE    || "cmp-loads";
const USERS_TABLE    = process.env.USERS_TABLE    || "cmp-users";
const COMPANIES_TABLE = process.env.COMPANIES_TABLE || "cmp-companies";

const db = new DynamoDBClient({ region: REGION });

async function scanAll(table) {
  const items = [];
  let lastKey;
  do {
    const result = await db.send(new ScanCommand({
      TableName: table,
      ExclusiveStartKey: lastKey,
    }));
    (result.Items || []).forEach(i => items.push(unmarshall(i)));
    lastKey = result.LastEvaluatedKey;
  } while (lastKey);
  return items;
}

async function stampTenantId(table, key, tenantId) {
  await db.send(new UpdateItemCommand({
    TableName: table,
    Key: marshall(key),
    UpdateExpression: "SET tenantId = :tid",
    ConditionExpression: "attribute_not_exists(tenantId)",
    ExpressionAttributeValues: marshall({ ":tid": tenantId }),
  }));
}

async function run() {
  console.log("─── CMP Multi-Tenant Migration ───────────────────────────────");
  console.log(`Seed tenantId : ${SEED_TENANT_ID}`);
  console.log(`Company       : ${COMPANY_NAME}`);
  console.log(`Admin email   : ${ADMIN_EMAIL}`);
  console.log("");

  // ── 1. Create company record (skip if already exists) ─────────────────────
  const existing = await db.send(new GetItemCommand({
    TableName: COMPANIES_TABLE,
    Key: marshall({ tenantId: SEED_TENANT_ID }),
  }));

  if (!existing.Item) {
    const company = {
      tenantId:    SEED_TENANT_ID,
      companyName: COMPANY_NAME,
      adminEmail:  ADMIN_EMAIL,
      plan:        "pro",   // existing company gets pro plan
      status:      "active",
      createdAt:   new Date().toISOString(),
      migratedAt:  new Date().toISOString(),
    };
    await db.send(new PutItemCommand({
      TableName: COMPANIES_TABLE,
      Item: marshall(company),
    }));
    console.log(`✅ Created company record for "${COMPANY_NAME}" (tenantId: ${SEED_TENANT_ID})`);
  } else {
    console.log(`ℹ️  Company record already exists — skipping create.`);
  }

  // ── 2. Stamp all loads ─────────────────────────────────────────────────────
  console.log("\nScanning loads…");
  const loads = await scanAll(LOADS_TABLE);
  const loadsToMigrate = loads.filter(l => !l.tenantId);
  console.log(`  Found ${loads.length} total loads, ${loadsToMigrate.length} need tenantId.`);

  let loadOk = 0, loadSkip = 0, loadErr = 0;
  for (const load of loadsToMigrate) {
    try {
      await stampTenantId(LOADS_TABLE, { id: load.id }, SEED_TENANT_ID);
      loadOk++;
      process.stdout.write(`\r  Stamped ${loadOk} loads…`);
    } catch (err) {
      if (err.name === "ConditionalCheckFailedException") {
        loadSkip++;
      } else {
        console.error(`\n  Error updating load ${load.id}:`, err.message);
        loadErr++;
      }
    }
  }
  console.log(`\n  ✅ ${loadOk} loads stamped, ${loadSkip} already had tenantId, ${loadErr} errors.`);

  // ── 3. Stamp all users ─────────────────────────────────────────────────────
  console.log("\nScanning users…");
  const users = await scanAll(USERS_TABLE);
  const usersToMigrate = users.filter(u => !u.tenantId);
  console.log(`  Found ${users.length} total users, ${usersToMigrate.length} need tenantId.`);

  let userOk = 0, userSkip = 0, userErr = 0;
  for (const user of usersToMigrate) {
    try {
      // Also stamp companyName onto users
      await db.send(new UpdateItemCommand({
        TableName: USERS_TABLE,
        Key: marshall({ email: user.email }),
        UpdateExpression: "SET tenantId = :tid, companyName = :cn",
        ConditionExpression: "attribute_not_exists(tenantId)",
        ExpressionAttributeValues: marshall({ ":tid": SEED_TENANT_ID, ":cn": COMPANY_NAME }),
      }));
      userOk++;
      process.stdout.write(`\r  Stamped ${userOk} users…`);
    } catch (err) {
      if (err.name === "ConditionalCheckFailedException") {
        userSkip++;
      } else {
        console.error(`\n  Error updating user ${user.email}:`, err.message);
        userErr++;
      }
    }
  }
  console.log(`\n  ✅ ${userOk} users stamped, ${userSkip} already had tenantId, ${userErr} errors.`);

  console.log("\n─── Migration complete ────────────────────────────────────────");
  console.log("Next steps:");
  console.log("  1. Deploy the updated SAM stack (sam deploy) to create the TenantIndex GSIs.");
  console.log("  2. Wait for the GSIs to finish building (check DynamoDB console).");
  console.log("  3. Set SEED_TENANT_ID in your JWT_SECRET parameter overrides so existing");
  console.log(`     users log in and get tenantId="${SEED_TENANT_ID}" in their token.`);
  console.log("  4. Add STRIPE_SECRET and STRIPE_WEBHOOK_SECRET to your SAM deploy params.");
}

run().catch(err => {
  console.error("Migration failed:", err);
  process.exit(1);
});
