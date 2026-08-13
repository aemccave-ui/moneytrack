#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / "scripts/api-3-telegram-initdata-verifier.fragment.js").read_text(encoding="utf-8")
NS = uuid.UUID("2c203a29-f4f6-44e5-b261-692ce8b30d69")

CODE = "n8n-nodes-base.code"
WEBHOOK = "n8n-nodes-base.webhook"
IF = "n8n-nodes-base.if"
POSTGRES = "n8n-nodes-base.postgres"
RESPOND = "n8n-nodes-base.respondToWebhook"


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def node(node_type: str, name: str, parameters: dict, x: int, y: int, version=2) -> dict:
    return {
        "parameters": parameters,
        "type": node_type,
        "typeVersion": version,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


def webhook(name: str, path: str, method: str, y: int) -> dict:
    result = node(
        WEBHOOK,
        name,
        {
            "path": path,
            "httpMethod": method,
            "responseMode": "responseNode",
            "options": {},
        },
        -900,
        y,
        2.1,
    )
    result["webhookId"] = uid("webhook:" + name)
    return result


def code(name: str, js: str, x: int, y: int) -> dict:
    return node(CODE, name, {"jsCode": js}, x, y, 2)


def if_node(name: str, expression: str, x: int, y: int) -> dict:
    return node(
        IF,
        name,
        {
            "conditions": {
                "options": {
                    "caseSensitive": True,
                    "leftValue": "",
                    "typeValidation": "strict",
                    "version": 2,
                },
                "conditions": [{
                    "id": uid(name + ":condition"),
                    "leftValue": expression,
                    "rightValue": "",
                    "operator": {
                        "type": "boolean",
                        "operation": "true",
                        "singleValue": True,
                    },
                }],
                "combinator": "and",
            },
            "options": {},
        },
        x,
        y,
        2.2,
    )


def postgres(name: str, query: str, x: int, y: int, credential_id: str, credential_name: str) -> dict:
    result = node(
        POSTGRES,
        name,
        {"operation": "executeQuery", "query": query, "options": {}},
        x,
        y,
        2.6,
    )
    result["credentials"] = {"postgres": {"id": credential_id, "name": credential_name}}
    result["alwaysOutputData"] = True
    result["onError"] = "continueRegularOutput"
    return result


def respond(name: str, x: int, y: int) -> dict:
    return node(
        RESPOND,
        name,
        {
            "respondWith": "json",
            "responseBody": "={{ JSON.stringify($json.ok === false ? { ok:false, error:$json.error } : { ok:true, data:$json.data }) }}",
            "options": {"responseCode": "={{ $json.http_status || 200 }}"},
        },
        x,
        y,
        1.4,
    )


def connect(connections: dict, source: str, branches: list[list[str]]) -> None:
    connections[source] = {
        "main": [[{"node": target, "type": "main", "index": 0} for target in branch] for branch in branches]
    }


AUTH_BASE = f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const item = $input.first();
const envelope = item.json || {{}};
const headers = envelope.headers || {{}};
const query = envelope.query || {{}};
const body = envelope.body || {{}};
const initData =
  headers["x-telegram-init-data"] ||
  headers["X-Telegram-Init-Data"] ||
  query.initData ||
  query.init_data ||
  null;
const auth = moneytrackVerifyTelegramInitData({{
  crypto,
  initData,
  botToken: $env.MONEYTRACK_BOT_TOKEN,
  maxAgeSeconds: $env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,
  maxFutureSkewSeconds: $env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS
}});
const fail = (code, http_status=400) => [{{json:{{ok:false,http_status,error:{{code}}}}}}];
if (!auth.ok) return [{{json:auth}}];
'''

STATUS_VERIFY = AUTH_BASE + r'''
const deviceId = String(query.device_id || "").trim();
if (deviceId.length > 512) return fail("BIOMETRIC_DEVICE_ID_INVALID");
return [{json:{
  ok:true,
  telegram_user_id:auth.telegram_user_id,
  username:auth.user?.username || null,
  first_name:auth.user?.first_name || null,
  telegram_language_code:auth.user?.language_code || null,
  device_id:deviceId || null
}}];
'''

# Class B security-management routes deliberately perform only canonical
# Telegram verification before the transformer inserts the MoneyTrack unlock
# boundary. Request/current-PIN validation happens after that second gate.
TELEGRAM_ONLY_VERIFY = AUTH_BASE + r'''
return [{json:{ok:true,telegram_user_id:auth.telegram_user_id}}];
'''

PIN_SETUP_PREPARE = AUTH_BASE + r'''
const pin = String(body.pin || "");
if (!/^\d{6}$/.test(pin)) return fail("PIN_FORMAT_INVALID");
const pepper = String($env.MONEYTRACK_PIN_PEPPER || "");
if (pepper.length < 32) return fail("SECURITY_SERVER_NOT_READY", 503);
const salt = crypto.randomBytes(16);
const verifier = crypto.scryptSync(
  Buffer.from(pin + "\u0000" + pepper, "utf8"),
  salt,
  32,
  {N:32768,r:8,p:1,maxmem:64*1024*1024}
);
const unlockToken = crypto.randomBytes(32).toString("base64url");
const unlockHash = crypto.createHash("sha256").update(unlockToken, "utf8").digest("hex");
return [{json:{
  ok:true,
  telegram_user_id:auth.telegram_user_id,
  pin_salt:salt.toString("hex"),
  pin_verifier:verifier.toString("hex"),
  unlock_token:unlockToken,
  unlock_token_hash:unlockHash
}}];
'''

PIN_UNLOCK_VERIFY = AUTH_BASE + r'''
return [{json:{ok:true,telegram_user_id:auth.telegram_user_id}}];
'''

PIN_CHECK = r'''const crypto = require("crypto");
const state = $input.first().json || {};
const request = $("PIN Unlock Webhook").first().json || {};
const body = request.body || {};
const pin = String(body.pin || "");
const fail = (code, extra={}) => [{json:{ok:false,pin_valid:false,error_code:code,...extra}}];

if (!state.user_id) return fail("USER_NOT_FOUND");
if (state.pin_enabled !== true) return fail("PIN_NOT_ENABLED", {user_id:Number(state.user_id)});
if (state.locked_until && new Date(state.locked_until).getTime() > Date.now()) {
  return fail("PIN_LOCKED", {user_id:Number(state.user_id)});
}
if (!/^\d{6}$/.test(pin)) {
  return fail("PIN_INVALID", {user_id:Number(state.user_id),record_failure:true});
}
const pepper = String($env.MONEYTRACK_PIN_PEPPER || "");
if (pepper.length < 32) return fail("SECURITY_SERVER_NOT_READY", {user_id:Number(state.user_id),http_status:503});

let actual;
try {
  actual = crypto.scryptSync(
    Buffer.from(pin + "\u0000" + pepper, "utf8"),
    Buffer.from(String(state.pin_salt || ""), "hex"),
    32,
    {N:32768,r:8,p:1,maxmem:64*1024*1024}
  );
} catch {
  return fail("SECURITY_SERVER_NOT_READY", {user_id:Number(state.user_id),http_status:503});
}
const expectedHex = String(state.pin_verifier || "");
const expected = /^[0-9a-f]{64}$/.test(expectedHex) ? Buffer.from(expectedHex, "hex") : Buffer.alloc(0);
const valid = expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
if (!valid) return fail("PIN_INVALID", {user_id:Number(state.user_id),record_failure:true});

const unlockToken = crypto.randomBytes(32).toString("base64url");
const unlockHash = crypto.createHash("sha256").update(unlockToken, "utf8").digest("hex");
return [{json:{
  ok:true,
  pin_valid:true,
  user_id:Number(state.user_id),
  unlock_token:unlockToken,
  unlock_token_hash:unlockHash
}}];
'''

PIN_CHANGE_CHECK = r'''const crypto = require("crypto");
const state = $input.first().json || {};
const request = $("PIN Change Webhook").first().json || {};
const body = request.body || {};
const currentPin = String(body.current_pin || "");
const newPin = String(body.new_pin || "");
const repeatPin = String(body.new_pin_repeat || "");
const fail = (code, extra={}) => [{json:{ok:false,pin_valid:false,error_code:code,...extra}}];
if (!state.user_id) return fail("USER_NOT_FOUND", {http_status:404});
if (state.pin_enabled !== true) return fail("PIN_NOT_ENABLED", {user_id:Number(state.user_id)});
if (state.locked_until && new Date(state.locked_until).getTime() > Date.now()) return fail("PIN_LOCKED", {user_id:Number(state.user_id)});
if (!/^\d{6}$/.test(newPin) || !/^\d{6}$/.test(repeatPin)) return fail("PIN_FORMAT_INVALID", {user_id:Number(state.user_id),http_status:400});
if (newPin !== repeatPin) return fail("PIN_CONFIRM_MISMATCH", {user_id:Number(state.user_id),http_status:400});
if (!/^\d{6}$/.test(currentPin)) return fail("PIN_INVALID", {user_id:Number(state.user_id),record_failure:true});
const pepper = String($env.MONEYTRACK_PIN_PEPPER || "");
if (pepper.length < 32) return fail("SECURITY_SERVER_NOT_READY", {user_id:Number(state.user_id),http_status:503});
const params = {N:32768,r:8,p:1,maxmem:64*1024*1024};
let actual;
try { actual = crypto.scryptSync(Buffer.from(currentPin + "\u0000" + pepper, "utf8"), Buffer.from(String(state.pin_salt || ""), "hex"), 32, params); }
catch { return fail("SECURITY_SERVER_NOT_READY", {user_id:Number(state.user_id),http_status:503}); }
const expectedHex = String(state.pin_verifier || "");
const expected = /^[0-9a-f]{64}$/.test(expectedHex) ? Buffer.from(expectedHex, "hex") : Buffer.alloc(0);
if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) return fail("PIN_INVALID", {user_id:Number(state.user_id),record_failure:true});
const newSalt = crypto.randomBytes(16);
const newVerifier = crypto.scryptSync(Buffer.from(newPin + "\u0000" + pepper, "utf8"), newSalt, 32, params);
const unlockToken = crypto.randomBytes(32).toString("base64url");
const unlockHash = crypto.createHash("sha256").update(unlockToken, "utf8").digest("hex");
return [{json:{ok:true,pin_valid:true,user_id:Number(state.user_id),expected_security_version:Number(state.security_version),pin_salt:newSalt.toString("hex"),pin_verifier:newVerifier.toString("hex"),unlock_token:unlockToken,unlock_token_hash:unlockHash}}];'''

DISABLE_CHECK = r'''const crypto = require("crypto");
const state = $input.first().json || {};
const request = $("Security Disable Webhook").first().json || {};
const body = request.body || {};
const currentPin = String(body.current_pin || "");
const fail = (code, extra={}) => [{json:{ok:false,pin_valid:false,error_code:code,...extra}}];
if (!state.user_id) return fail("USER_NOT_FOUND", {http_status:404});
if (state.pin_enabled !== true) return fail("PIN_NOT_ENABLED", {user_id:Number(state.user_id)});
if (body.confirm !== true) return fail("SECURITY_DISABLE_CONFIRMATION_REQUIRED", {user_id:Number(state.user_id),http_status:400});
if (state.locked_until && new Date(state.locked_until).getTime() > Date.now()) return fail("PIN_LOCKED", {user_id:Number(state.user_id)});
if (!/^\d{6}$/.test(currentPin)) return fail("PIN_INVALID", {user_id:Number(state.user_id),record_failure:true});
const pepper = String($env.MONEYTRACK_PIN_PEPPER || "");
if (pepper.length < 32) return fail("SECURITY_SERVER_NOT_READY", {user_id:Number(state.user_id),http_status:503});
let actual;
try { actual = crypto.scryptSync(Buffer.from(currentPin + "\u0000" + pepper, "utf8"), Buffer.from(String(state.pin_salt || ""), "hex"), 32, {N:32768,r:8,p:1,maxmem:64*1024*1024}); }
catch { return fail("SECURITY_SERVER_NOT_READY", {user_id:Number(state.user_id),http_status:503}); }
const expectedHex = String(state.pin_verifier || "");
const expected = /^[0-9a-f]{64}$/.test(expectedHex) ? Buffer.from(expectedHex, "hex") : Buffer.alloc(0);
if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) return fail("PIN_INVALID", {user_id:Number(state.user_id),record_failure:true});
return [{json:{ok:true,pin_valid:true,user_id:Number(state.user_id),expected_security_version:Number(state.security_version)}}];'''

BIOMETRIC_UNLOCK_PREPARE = AUTH_BASE + r'''
const deviceId = String(body.device_id || "").trim();
const token = String(body.biometric_token || "");
if (!deviceId || deviceId.length > 512) return fail("BIOMETRIC_DEVICE_ID_INVALID");
if (!token || token.length > 1024) return fail("BIOMETRIC_TOKEN_INVALID");
return [{json:{
  ok:true,
  telegram_user_id:auth.telegram_user_id,
  device_id:deviceId,
  biometric_token_hash:crypto.createHash("sha256").update(token, "utf8").digest("hex")
}}];
'''

BIOMETRIC_SESSION = r'''const crypto = require("crypto");
const row = $input.first().json || {};
if (row.biometric_ok !== true || !row.user_id) {
  return [{json:{ok:false,http_status:401,error:{code:row.error_code || "BIOMETRIC_INVALID"}}}];
}
const unlockToken = crypto.randomBytes(32).toString("base64url");
const unlockHash = crypto.createHash("sha256").update(unlockToken, "utf8").digest("hex");
return [{json:{
  ok:true,
  user_id:Number(row.user_id),
  unlock_token:unlockToken,
  unlock_token_hash:unlockHash
}}];
'''

BIOMETRIC_ENROLL_PREPARE = r'''const crypto = require("crypto");
const request = $("Biometric Enroll Webhook").first().json || {};
const body = request.body || {};
const deviceId = String(body.device_id || "").trim();
const fail = (code,http_status=400) => [{json:{ok:false,http_status,error:{code}}}];
if (!deviceId || deviceId.length > 512) return fail("BIOMETRIC_DEVICE_ID_INVALID");
const token = crypto.randomBytes(32).toString("base64url");
return [{json:{
  ok:true,
  telegram_user_id:Number($json.telegram_user_id),
  device_id:deviceId,
  biometric_token:token,
  biometric_token_hash:crypto.createHash("sha256").update(token, "utf8").digest("hex")
}}];
'''

BIOMETRIC_REVOKE_PREPARE = r'''const request = $("Biometric Revoke Webhook").first().json || {};
const body = request.body || {};
const deviceId = String(body.device_id || "").trim();
const fail = (code,http_status=400) => [{json:{ok:false,http_status,error:{code}}}];
if (!deviceId || deviceId.length > 512) return fail("BIOMETRIC_DEVICE_ID_INVALID");
return [{json:{
  ok:true,
  telegram_user_id:Number($json.telegram_user_id),
  device_id:deviceId
}}];
'''

FORMAT_STATUS = r'''const row=$input.first().json||{};
if (row.error) return [{json:{ok:false,http_status:500,error:{code:"SECURITY_STATUS_FAILED"}}}];
if (!row.user_id) return [{json:{ok:false,http_status:404,error:{code:"USER_NOT_FOUND"}}}];
return [{json:{ok:true,http_status:200,data:{
  protection_enabled:row.pin_enabled===true,
  pin_enabled:row.pin_enabled===true,
  failed_attempts:Number(row.failed_attempts||0),
  locked_until:row.locked_until||null,
  security_version:Number(row.security_version||1),
  biometric_enrolled:row.biometric_enrolled===true
}}}];'''

FORMAT_SETUP = r'''const row=$input.first().json||{};
if (row.error) {
  const raw=String(row.error.message||row.error||"SECURITY_SETUP_FAILED");
  const match=raw.match(/\b([A-Z][A-Z0-9_]+)\b/);
  return [{json:{ok:false,http_status:400,error:{code:match?match[1]:"SECURITY_SETUP_FAILED"}}}];
}
const prepared=$("PIN Setup Verify").first().json||{};
return [{json:{ok:true,http_status:200,data:{
  protection_enabled:true,
  unlock_token:prepared.unlock_token,
  expires_at:row.expires_at||null
}}}];'''

FORMAT_UNLOCK_SUCCESS = r'''const row=$input.first().json||{};
const prepared=$("PIN Check").first().json||{};
if (row.error) return [{json:{ok:false,http_status:500,error:{code:"UNLOCK_SESSION_FAILED"}}}];
return [{json:{ok:true,http_status:200,data:{
  unlock_token:prepared.unlock_token,
  expires_at:row.expires_at||null
}}}];'''

FORMAT_PIN_FAILURE = r'''const row=$input.first().json||{};
const code=String(row.error_code||"PIN_INVALID");
return [{json:{ok:false,http_status:code==="PIN_LOCKED"?429:401,error:{
  code,
  locked_until:row.locked_until||null
}}}];'''

FORMAT_DIRECT_PIN_FAILURE = r'''const row=$input.first().json||{};
const code=String(row.error_code||"PIN_INVALID");
return [{json:{ok:false,http_status:Number(row.http_status|| (code==="PIN_LOCKED"?429:401)),error:{code}}}];'''

FORMAT_BIOMETRIC_UNLOCK = r'''const row=$input.first().json||{};
const prepared=$("Biometric Session Token").first().json||{};
if (row.error) return [{json:{ok:false,http_status:500,error:{code:"UNLOCK_SESSION_FAILED"}}}];
return [{json:{ok:true,http_status:200,data:{
  unlock_token:prepared.unlock_token,
  expires_at:row.expires_at||null
}}}];'''

FORMAT_ENROLL = r'''const row=$input.first().json||{};
if (row.error) {
  const raw=String(row.error.message||row.error||"BIOMETRIC_ENROLL_FAILED");
  const match=raw.match(/\b([A-Z][A-Z0-9_]+)\b/);
  return [{json:{ok:false,http_status:400,error:{code:match?match[1]:"BIOMETRIC_ENROLL_FAILED"}}}];
}
const prepared=$("Biometric Enroll Verify").first().json||{};
return [{json:{ok:true,http_status:200,data:{
  device_id:prepared.device_id,
  biometric_token:prepared.biometric_token
}}}];'''

FORMAT_REVOKE = r'''const row=$input.first().json||{};
if (row.error) return [{json:{ok:false,http_status:500,error:{code:"BIOMETRIC_REVOKE_FAILED"}}}];
return [{json:{ok:true,http_status:200,data:{revoked:row.revoked===true}}}];'''

FORMAT_CHANGE_SUCCESS = r'''const row=$input.first().json||{};
const prepared=$("PIN Change Check").first().json||{};
if (row.error) { const raw=String(row.error.message||row.error||"PIN_CHANGE_FAILED"); const match=raw.match(/\b([A-Z][A-Z0-9_]+)\b/); return [{json:{ok:false,http_status:409,error:{code:match?match[1]:"PIN_CHANGE_FAILED"}}}]; }
return [{json:{ok:true,http_status:200,data:{protection_enabled:true,unlock_token:prepared.unlock_token,expires_at:row.expires_at||null,security_version:Number(row.security_version||0)}}}];'''

FORMAT_DISABLE_SUCCESS = r'''const row=$input.first().json||{};
if (row.error) { const raw=String(row.error.message||row.error||"SECURITY_DISABLE_FAILED"); const match=raw.match(/\b([A-Z][A-Z0-9_]+)\b/); return [{json:{ok:false,http_status:409,error:{code:match?match[1]:"SECURITY_DISABLE_FAILED"}}}]; }
return [{json:{ok:true,http_status:200,data:{protection_enabled:false,pin_enabled:false,security_version:Number(row.security_version||0),sessions_revoked:Number(row.sessions_revoked||0),biometrics_revoked:Number(row.biometrics_revoked||0)}}}];'''


def add_simple_route(nodes, connections, *, prefix, path, method, verify_js, query, format_js, y, cred_id, cred_name):
    wh = prefix + " Webhook"
    vr = prefix + " Verify"
    auth = prefix + " Telegram OK"
    db = prefix + " Backend"
    fm = prefix + " Format"
    rp = prefix + " Respond"
    nodes.extend([
        webhook(wh, path, method, y),
        code(vr, verify_js, -680, y),
        if_node(auth, "={{ $json.ok === true }}", -470, y),
        postgres(db, query, -240, y - 80, cred_id, cred_name),
        code(fm, format_js, 10, y - 80),
        respond(rp, 260, y),
    ])
    connect(connections, wh, [[vr]])
    connect(connections, vr, [[auth]])
    connect(connections, auth, [[db], [rp]])
    connect(connections, db, [[fm]])
    connect(connections, fm, [[rp]])


def build(credential_id: str, credential_name: str) -> dict:
    nodes = []
    connections = {}

    # First-user-safe Class A status: Telegram identity is cryptographically
    # verified before reusing the canonical idempotent user bootstrap boundary.
    nodes.extend([
        webhook("Security Status Webhook", "api/v1/security/status", "GET", -700),
        code("Security Status Verify", STATUS_VERIFY, -680, -700),
        if_node("Security Status Telegram OK", "={{ $json.ok === true }}", -470, -700),
        postgres("Security Status User Bootstrap", """select * from moneytrack.user_bootstrap_v1(
{{ $('Security Status Verify').first().json.telegram_user_id }}::bigint,
{{ $('Security Status Verify').first().json.username ? "'" + $('Security Status Verify').first().json.username.replace(/'/g,"''") + "'" : "NULL" }}::text,
{{ $('Security Status Verify').first().json.first_name ? "'" + $('Security Status Verify').first().json.first_name.replace(/'/g,"''") + "'" : "NULL" }}::text,
{{ $('Security Status Verify').first().json.telegram_language_code ? "'" + $('Security Status Verify').first().json.telegram_language_code.replace(/'/g,"''") + "'" : "NULL" }}::text
);""", -240, -780, credential_id, credential_name),
        postgres("Security Status Backend", """select * from moneytrack.security_status_v1(
{{ $('Security Status Verify').first().json.telegram_user_id }}::bigint,
{{ $('Security Status Verify').first().json.device_id ? "'" + $('Security Status Verify').first().json.device_id.replace(/'/g,"''") + "'" : "NULL" }}::text
);""", 10, -780, credential_id, credential_name),
        code("Security Status Format", FORMAT_STATUS, 260, -780),
        respond("Security Status Respond", 510, -700),
    ])
    connect(connections, "Security Status Webhook", [["Security Status Verify"]])
    connect(connections, "Security Status Verify", [["Security Status Telegram OK"]])
    connect(connections, "Security Status Telegram OK", [["Security Status User Bootstrap"], ["Security Status Respond"]])
    connect(connections, "Security Status User Bootstrap", [["Security Status Backend"]])
    connect(connections, "Security Status Backend", [["Security Status Format"]])
    connect(connections, "Security Status Format", [["Security Status Respond"]])

    add_simple_route(
        nodes, connections,
        prefix="PIN Setup",
        path="api/v1/security/pin/setup",
        method="POST",
        verify_js=PIN_SETUP_PREPARE,
        query="""with u as (
  select id::bigint as user_id
  from moneytrack.app_users
  where telegram_user_id={{ $json.telegram_user_id }}::bigint
  limit 1
), setup as (
  select x.*
  from u
  cross join lateral moneytrack.security_setup_pin_v1(
    u.user_id,
    '{{ $json.pin_salt }}'::text,
    '{{ $json.pin_verifier }}'::text
  ) x
), issued as (
  select s.*
  from setup
  cross join u
  cross join lateral moneytrack.security_issue_session_v1(
    u.user_id,
    '{{ $json.unlock_token_hash }}'::text,
    900
  ) s
)
select u.user_id, setup.pin_enabled, setup.security_version, issued.expires_at
from u, setup, issued;""",
        format_js=FORMAT_SETUP,
        y=-420,
        cred_id=credential_id,
        cred_name=credential_name,
    )

    nodes.extend([
        webhook("PIN Unlock Webhook", "api/v1/security/pin/unlock", "POST", -120),
        code("PIN Unlock Verify", PIN_UNLOCK_VERIFY, -680, -120),
        if_node("PIN Unlock Telegram OK", "={{ $json.ok === true }}", -470, -120),
        postgres(
            "PIN State",
            "select * from moneytrack.security_pin_state_v1({{ $json.telegram_user_id }}::bigint);",
            -240, -200, credential_id, credential_name,
        ),
        code("PIN Check", PIN_CHECK, 10, -200),
        if_node("PIN Valid", "={{ $json.pin_valid === true }}", 240, -200),
        postgres(
            "PIN Unlock Success",
            """with reset as (
  select moneytrack.security_record_pin_success_v1({{ $json.user_id }}::bigint) as done
), issued as (
  select s.*
  from reset
  cross join lateral moneytrack.security_issue_session_v1(
    {{ $json.user_id }}::bigint,
    '{{ $json.unlock_token_hash }}'::text,
    900
  ) s
)
select * from issued;""",
            470, -280, credential_id, credential_name,
        ),
        code("PIN Unlock Success Format", FORMAT_UNLOCK_SUCCESS, 700, -280),
        if_node("PIN Failure Recorded?", "={{ $json.record_failure === true }}", 470, -80),
        postgres(
            "PIN Failure",
            "select * from moneytrack.security_record_pin_failure_v1({{ $json.user_id }}::bigint);",
            700, -120, credential_id, credential_name,
        ),
        code("PIN Failure Format", FORMAT_PIN_FAILURE, 930, -120),
        code("PIN Direct Failure Format", FORMAT_DIRECT_PIN_FAILURE, 700, 20),
        respond("PIN Unlock Respond", 1170, -120),
    ])
    connect(connections, "PIN Unlock Webhook", [["PIN Unlock Verify"]])
    connect(connections, "PIN Unlock Verify", [["PIN Unlock Telegram OK"]])
    connect(connections, "PIN Unlock Telegram OK", [["PIN State"], ["PIN Unlock Respond"]])
    connect(connections, "PIN State", [["PIN Check"]])
    connect(connections, "PIN Check", [["PIN Valid"]])
    connect(connections, "PIN Valid", [["PIN Unlock Success"], ["PIN Failure Recorded?"]])
    connect(connections, "PIN Unlock Success", [["PIN Unlock Success Format"]])
    connect(connections, "PIN Unlock Success Format", [["PIN Unlock Respond"]])
    connect(connections, "PIN Failure Recorded?", [["PIN Failure"], ["PIN Direct Failure Format"]])
    connect(connections, "PIN Failure", [["PIN Failure Format"]])
    connect(connections, "PIN Failure Format", [["PIN Unlock Respond"]])
    connect(connections, "PIN Direct Failure Format", [["PIN Unlock Respond"]])

    nodes.extend([
        webhook("Biometric Unlock Webhook", "api/v1/security/biometric/unlock", "POST", 220),
        code("Biometric Unlock Prepare", BIOMETRIC_UNLOCK_PREPARE, -680, 220),
        if_node("Biometric Unlock Telegram OK", "={{ $json.ok === true }}", -470, 220),
        postgres(
            "Biometric Validate",
            """select * from moneytrack.security_validate_biometric_v1(
{{ $json.telegram_user_id }}::bigint,
'{{ $json.device_id.replace(/'/g,"''") }}'::text,
'{{ $json.biometric_token_hash }}'::text
);""",
            -240, 140, credential_id, credential_name,
        ),
        code("Biometric Session Token", BIOMETRIC_SESSION, 10, 140),
        if_node("Biometric Valid", "={{ $json.ok === true }}", 240, 140),
        postgres(
            "Biometric Unlock Session",
            """select * from moneytrack.security_issue_session_v1(
{{ $json.user_id }}::bigint,
'{{ $json.unlock_token_hash }}'::text,
900
);""",
            470, 60, credential_id, credential_name,
        ),
        code("Biometric Unlock Format", FORMAT_BIOMETRIC_UNLOCK, 700, 60),
        respond("Biometric Unlock Respond", 930, 220),
    ])
    connect(connections, "Biometric Unlock Webhook", [["Biometric Unlock Prepare"]])
    connect(connections, "Biometric Unlock Prepare", [["Biometric Unlock Telegram OK"]])
    connect(connections, "Biometric Unlock Telegram OK", [["Biometric Validate"], ["Biometric Unlock Respond"]])
    connect(connections, "Biometric Validate", [["Biometric Session Token"]])
    connect(connections, "Biometric Session Token", [["Biometric Valid"]])
    connect(connections, "Biometric Valid", [["Biometric Unlock Session"], ["Biometric Unlock Respond"]])
    connect(connections, "Biometric Unlock Session", [["Biometric Unlock Format"]])
    connect(connections, "Biometric Unlock Format", [["Biometric Unlock Respond"]])

    nodes.extend([
        webhook("PIN Change Webhook", "api/v1/security/pin/change", "POST", 500),
        code("PIN Change Verify", TELEGRAM_ONLY_VERIFY, -680, 500),
        if_node("PIN Change Telegram OK", "={{ $json.ok === true }}", -470, 500),
        postgres("PIN Change State", "select * from moneytrack.security_pin_state_v1({{ $json.telegram_user_id }}::bigint);", -240, 420, credential_id, credential_name),
        code("PIN Change Check", PIN_CHANGE_CHECK, 10, 420),
        if_node("PIN Change Valid", "={{ $json.pin_valid === true }}", 240, 420),
        postgres("PIN Change Backend", """select * from moneytrack.security_change_pin_v1(
{{ $json.user_id }}::bigint, {{ $json.expected_security_version }}::bigint,
'{{ $json.pin_salt }}'::text, '{{ $json.pin_verifier }}'::text,
'{{ $json.unlock_token_hash }}'::text, 900);""", 470, 340, credential_id, credential_name),
        code("PIN Change Success Format", FORMAT_CHANGE_SUCCESS, 700, 340),
        if_node("PIN Change Failure Recorded?", "={{ $json.record_failure === true }}", 470, 540),
        postgres("PIN Change Failure", "select * from moneytrack.security_record_pin_failure_v1({{ $json.user_id }}::bigint);", 700, 500, credential_id, credential_name),
        code("PIN Change Failure Format", FORMAT_PIN_FAILURE, 930, 500),
        code("PIN Change Direct Failure Format", FORMAT_DIRECT_PIN_FAILURE, 700, 620),
        respond("PIN Change Respond", 1170, 500),
    ])
    connect(connections, "PIN Change Webhook", [["PIN Change Verify"]])
    connect(connections, "PIN Change Verify", [["PIN Change Telegram OK"]])
    connect(connections, "PIN Change Telegram OK", [["PIN Change State"], ["PIN Change Respond"]])
    connect(connections, "PIN Change State", [["PIN Change Check"]])
    connect(connections, "PIN Change Check", [["PIN Change Valid"]])
    connect(connections, "PIN Change Valid", [["PIN Change Backend"], ["PIN Change Failure Recorded?"]])
    connect(connections, "PIN Change Backend", [["PIN Change Success Format"]])
    connect(connections, "PIN Change Success Format", [["PIN Change Respond"]])
    connect(connections, "PIN Change Failure Recorded?", [["PIN Change Failure"], ["PIN Change Direct Failure Format"]])
    connect(connections, "PIN Change Failure", [["PIN Change Failure Format"]])
    connect(connections, "PIN Change Failure Format", [["PIN Change Respond"]])
    connect(connections, "PIN Change Direct Failure Format", [["PIN Change Respond"]])

    nodes.extend([
        webhook("Security Disable Webhook", "api/v1/security/disable", "POST", 820),
        code("Security Disable Verify", TELEGRAM_ONLY_VERIFY, -680, 820),
        if_node("Security Disable Telegram OK", "={{ $json.ok === true }}", -470, 820),
        postgres("Security Disable State", "select * from moneytrack.security_pin_state_v1({{ $json.telegram_user_id }}::bigint);", -240, 740, credential_id, credential_name),
        code("Security Disable Check", DISABLE_CHECK, 10, 740),
        if_node("Security Disable Valid", "={{ $json.pin_valid === true }}", 240, 740),
        postgres("Security Disable Backend", """select * from moneytrack.security_disable_v1(
{{ $json.user_id }}::bigint, {{ $json.expected_security_version }}::bigint);""", 470, 660, credential_id, credential_name),
        code("Security Disable Success Format", FORMAT_DISABLE_SUCCESS, 700, 660),
        if_node("Security Disable Failure Recorded?", "={{ $json.record_failure === true }}", 470, 860),
        postgres("Security Disable Failure", "select * from moneytrack.security_record_pin_failure_v1({{ $json.user_id }}::bigint);", 700, 820, credential_id, credential_name),
        code("Security Disable Failure Format", FORMAT_PIN_FAILURE, 930, 820),
        code("Security Disable Direct Failure Format", FORMAT_DIRECT_PIN_FAILURE, 700, 940),
        respond("Security Disable Respond", 1170, 820),
    ])
    connect(connections, "Security Disable Webhook", [["Security Disable Verify"]])
    connect(connections, "Security Disable Verify", [["Security Disable Telegram OK"]])
    connect(connections, "Security Disable Telegram OK", [["Security Disable State"], ["Security Disable Respond"]])
    connect(connections, "Security Disable State", [["Security Disable Check"]])
    connect(connections, "Security Disable Check", [["Security Disable Valid"]])
    connect(connections, "Security Disable Valid", [["Security Disable Backend"], ["Security Disable Failure Recorded?"]])
    connect(connections, "Security Disable Backend", [["Security Disable Success Format"]])
    connect(connections, "Security Disable Success Format", [["Security Disable Respond"]])
    connect(connections, "Security Disable Failure Recorded?", [["Security Disable Failure"], ["Security Disable Direct Failure Format"]])
    connect(connections, "Security Disable Failure", [["Security Disable Failure Format"]])
    connect(connections, "Security Disable Failure Format", [["Security Disable Respond"]])
    connect(connections, "Security Disable Direct Failure Format", [["Security Disable Respond"]])

    nodes.extend([
        webhook("Biometric Enroll Webhook", "api/v1/security/biometric/enroll", "POST", 1140),
        code("Biometric Enroll Verify", TELEGRAM_ONLY_VERIFY, -680, 1140),
        if_node("Biometric Enroll Telegram OK", "={{ $json.ok === true }}", -470, 1140),
        code("Biometric Enroll Prepare", BIOMETRIC_ENROLL_PREPARE, -240, 1060),
        postgres("Biometric Enroll Backend", """with u as (select id::bigint as user_id from moneytrack.app_users where telegram_user_id={{ $json.telegram_user_id }}::bigint limit 1)
select e.* from u cross join lateral moneytrack.security_enroll_biometric_v1(u.user_id,'{{ $json.device_id.replace(/'/g,"''") }}'::text,'{{ $json.biometric_token_hash }}'::text) e;""", 10, 1060, credential_id, credential_name),
        code("Biometric Enroll Format", FORMAT_ENROLL, 260, 1060),
        respond("Biometric Enroll Respond", 510, 1140),
    ])
    connect(connections, "Biometric Enroll Webhook", [["Biometric Enroll Verify"]])
    connect(connections, "Biometric Enroll Verify", [["Biometric Enroll Telegram OK"]])
    connect(connections, "Biometric Enroll Telegram OK", [["Biometric Enroll Prepare"], ["Biometric Enroll Respond"]])
    connect(connections, "Biometric Enroll Prepare", [["Biometric Enroll Backend"]])
    connect(connections, "Biometric Enroll Backend", [["Biometric Enroll Format"]])
    connect(connections, "Biometric Enroll Format", [["Biometric Enroll Respond"]])

    nodes.extend([
        webhook("Biometric Revoke Webhook", "api/v1/security/biometric/revoke", "POST", 1420),
        code("Biometric Revoke Verify", TELEGRAM_ONLY_VERIFY, -680, 1420),
        if_node("Biometric Revoke Telegram OK", "={{ $json.ok === true }}", -470, 1420),
        code("Biometric Revoke Prepare", BIOMETRIC_REVOKE_PREPARE, -240, 1340),
        postgres("Biometric Revoke Backend", """with u as (select id::bigint as user_id from moneytrack.app_users where telegram_user_id={{ $json.telegram_user_id }}::bigint limit 1)
select moneytrack.security_revoke_biometric_v1(u.user_id,'{{ $json.device_id.replace(/'/g,"''") }}'::text) as revoked from u;""", 10, 1340, credential_id, credential_name),
        code("Biometric Revoke Format", FORMAT_REVOKE, 260, 1340),
        respond("Biometric Revoke Respond", 510, 1420),
    ])
    connect(connections, "Biometric Revoke Webhook", [["Biometric Revoke Verify"]])
    connect(connections, "Biometric Revoke Verify", [["Biometric Revoke Telegram OK"]])
    connect(connections, "Biometric Revoke Telegram OK", [["Biometric Revoke Prepare"], ["Biometric Revoke Respond"]])
    connect(connections, "Biometric Revoke Prepare", [["Biometric Revoke Backend"]])
    connect(connections, "Biometric Revoke Backend", [["Biometric Revoke Format"]])
    connect(connections, "Biometric Revoke Format", [["Biometric Revoke Respond"]])

    return {
        "id": "SEC001SecurityAPI202608",
        "name": "MoneyTrack Security API",
        "nodes": nodes,
        "connections": connections,
        "settings": {
            "executionOrder": "v1",
            "saveDataErrorExecution": "none",
            "saveDataSuccessExecution": "none",
            "saveExecutionProgress": False,
        },
        "active": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--postgres-credential-id", default="tM27zg5m7tREo2ep")
    parser.add_argument("--postgres-credential-name", default="Postgres account")
    args = parser.parse_args()
    workflow = build(args.postgres_credential_id, args.postgres_credential_name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"security_api={workflow['id']} nodes={len(workflow['nodes'])} path={args.output}")


if __name__ == "__main__":
    main()
