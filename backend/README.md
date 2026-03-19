# CMP Tracking – AWS Backend Setup Guide

This folder contains the complete serverless backend for CMP Tracking.  
It runs on **AWS Lambda + API Gateway + DynamoDB**, deployed with **AWS SAM**.

---

## Architecture

```
iPhone App (Swift)       Dispatcher Web Portal
[iOS Drivers/Dispatchers]  [Any browser – dispatcher.html]
        │                          │
        └──────────┬───────────────┘
                   ▼
       API Gateway (HTTP API)  ──── /prod
                   │
  ┌────────────────┴───────────────────────────────────┐
  │  Lambda Functions (Node.js 20)                     │
  │  POST /users/register   → register.js              │
  │  POST /users/login      → login.js                 │
  │  GET  /loads            → getLoads.js              │
  │  POST /loads            → createLoad.js            │
  │  PATCH /loads/{id}/status → updateLoadStatus.js    │
  │  POST /loads/{id}/send-driver-link → sendDriverLink│
  │  POST /locations        → postLocation.js          │
  │  GET  /loads/{id}/location → getLocation.js        │
  │  GET  /track/{token}    → trackByToken.js          │
  └────────────────────────────────────────────────────┘
                   │
  ┌────────────────┴──────────────┐
  │  DynamoDB Tables               │
  │  cmp-users      PK: email      │
  │  cmp-loads      PK: id         │
  │  cmp-locations  PK: loadId     │
  └───────────────────────────────┘

Static HTML (S3 / any host)
  dispatcher.html       ← Dispatcher web portal
  driver-tracking.html  ← Driver browser tracking page
  track-shipment.html   ← Customer shipment tracking
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI | `brew install awscli` then `aws configure` |
| AWS SAM CLI | `brew install aws-sam-cli` |
| Node.js 20 | `brew install node` |

---

## Step 1 – Install npm dependencies

```bash
cd backend/src
npm install
```

---

## Step 2 – Store the JWT secret in SSM Parameter Store

```bash
aws ssm put-parameter \
  --name /cmp-tracking/jwt-secret \
  --value "CHOOSE_A_LONG_RANDOM_SECRET_STRING" \
  --type SecureString
```

> **Tip:** generate a secret with `openssl rand -base64 48`

---

## Step 3 – Build the SAM project

```bash
cd backend
sam build
```

---

## Step 4 – Deploy to AWS

```bash
sam deploy --guided
```

Answer the prompts:
- **Stack name:** `cmp-tracking`
- **Region:** `us-east-1` (or your preferred region)
- **Confirm changeset:** `y`
- **Allow SAM to create IAM roles:** `y`
- **Save arguments to samconfig.toml:** `y`

After deploy completes, SAM prints the **ApiBaseUrl** output.  
It looks like:
```
https://abc123def456.execute-api.us-east-1.amazonaws.com/prod
```

---

## Step 5 – Configure the iOS app

Open **`CMP Tracking/AWSConfig.swift`** and paste your URL:

```swift
enum AWSConfig {
    static let baseURL = "https://abc123def456.execute-api.us-east-1.amazonaws.com/prod"
}
```

Rebuild and reinstall the app. All sign-ups, logins, loads, and GPS fixes  
will now be saved to your DynamoDB tables.

---

## Step 6 – Configure the Dispatcher Web Portal

Open **`backend/dispatcher.html`** in a text editor and replace the `API_BASE` constant near the top of the `<script>` block:

```js
const API_BASE = "https://abc123def456.execute-api.us-east-1.amazonaws.com/prod";
```

Then host `dispatcher.html`, `driver-tracking.html`, and `track-shipment.html` anywhere static files are served — S3 + CloudFront is the easiest option:

```bash
# Create a public S3 bucket (or use an existing one)
aws s3 mb s3://cmp-tracking-portal --region us-east-1

# Upload the three HTML files
aws s3 cp backend/dispatcher.html      s3://cmp-tracking-portal/ --acl public-read
aws s3 cp backend/driver-tracking.html s3://cmp-tracking-portal/ --acl public-read
aws s3 cp backend/track-shipment.html  s3://cmp-tracking-portal/ --acl public-read
```

Your dispatcher portal is then accessible at:
```
https://cmp-tracking-portal.s3-website-us-east-1.amazonaws.com/dispatcher.html
```

> **CORS:** Make sure your API Gateway stage has CORS enabled for the S3/CloudFront domain, or use `*` during development.

---

## Step 6 – Verify it works

```bash
# Register a test user
curl -X POST https://<YOUR_URL>/prod/users/register \
  -H "Content-Type: application/json" \
  -d '{"name":"Test Driver","email":"test@cmp.com","phone":"555-0100","password":"pass123","role":"driver"}'

# Login and get a JWT token
curl -X POST https://<YOUR_URL>/prod/users/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@cmp.com","password":"pass123"}'
```

---

## DynamoDB Tables

| Table | Key | Description |
|-------|-----|-------------|
| `cmp-users` | PK: `email` | User accounts (passwords hashed with SHA-256) |
| `cmp-loads` | PK: `id`, GSI: `trackingToken` | Freight loads |
| `cmp-locations` | PK: `loadId`, SK: `timestamp` | GPS location history |

---

## Future – WebSocket Real-time Updates

The `NetworkManager.swift` already has WebSocket code. To enable real-time  
location streaming, add **AWS API Gateway WebSocket API** or replace with  
**AWS IoT Core** for lower-latency GPS streaming.

---

## Cost Estimate (Pay-per-request)

With 10 drivers sending GPS every 10 seconds for 8 hours/day:
- ~28,800 DynamoDB writes/driver/day
- **Free Tier covers ~83 million writes/month** — essentially free for a small fleet.
- API Gateway: **$1.00 per million requests**

Total estimated cost for a 20-truck fleet: **< $5/month**.
