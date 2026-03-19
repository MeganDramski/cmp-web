//
//  AWSConfig.swift
//  CMP Tracking
//
//  ─── PASTE YOUR API GATEWAY URL HERE AFTER DEPLOYING ───────────
//  Run:  sam deploy --guided
//  Then copy the "ApiBaseUrl" output value and paste it below.
//  ───────────────────────────────────────────────────────────────

enum AWSConfig {
    /// Base URL of your API Gateway stage.
    /// Example: "https://abc123def.execute-api.us-east-1.amazonaws.com/prod"
    static let baseURL = "https://abc12xyz.execute-api.us-east-1.amazonaws.com/prod"
}
