#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / 'scripts/api-3-telegram-initdata-verifier.fragment.js').read_text(encoding='utf-8')
NS = uuid.UUID('07db74e4-2bf6-4ba2-a437-905da5e60f0a')

PHOTO_PROCESSOR_ID = '5VC0EcFB21rwTfoI'
PHOTO_PROCESSOR_NAME = 'MoneyTrack Transaction Processor Photo'
TEXT_PROCESSOR_ID = 'f5ioJKyPTupUMV9h'
TEXT_PROCESSOR_NAME = 'MoneyTrack Transaction Processor Text'
VOICE_PROCESSOR_ID = 'Td7kvvrtqQK0FTJg'
VOICE_PROCESSOR_NAME = 'MoneyTrack Transaction Processor Voice'


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def webhook(name: str, path: str, y: int) -> dict:
    return {
        'parameters': {
            'path': path,
            'httpMethod': 'POST',
            'responseMode': 'responseNode',
            'options': {},
        },
        'type': 'n8n-nodes-base.webhook',
        'typeVersion': 2.1,
        'position': [-900, y],
        'id': uid(name),
        'name': name,
        'webhookId': uid('webhook:' + name),
    }


def code(name: str, js: str, x: int, y: int) -> dict:
    return {
        'parameters': {'jsCode': js},
        'type': 'n8n-nodes-base.code',
        'typeVersion': 2,
        'position': [x, y],
        'id': uid(name),
        'name': name,
    }


def if_node(name: str, x: int, y: int) -> dict:
    return {
        'parameters': {
            'conditions': {
                'options': {
                    'caseSensitive': True,
                    'leftValue': '',
                    'typeValidation': 'strict',
                    'version': 2,
                },
                'conditions': [{
                    'id': uid(name + ':condition'),
                    'leftValue': '={{ $json.ok }}',
                    'rightValue': '',
                    'operator': {
                        'type': 'boolean',
                        'operation': 'true',
                        'singleValue': True,
                    },
                }],
                'combinator': 'and',
            },
            'options': {},
        },
        'type': 'n8n-nodes-base.if',
        'typeVersion': 2.2,
        'position': [x, y],
        'id': uid(name),
        'name': name,
    }


def postgres(name: str, query: str, x: int, y: int, credential_id: str, credential_name: str) -> dict:
    return {
        'parameters': {'operation': 'executeQuery', 'query': query, 'options': {}},
        'type': 'n8n-nodes-base.postgres',
        'typeVersion': 2.6,
        'position': [x, y],
        'id': uid(name),
        'name': name,
        'alwaysOutputData': True,
        'credentials': {'postgres': {'id': credential_id, 'name': credential_name}},
        'onError': 'continueRegularOutput',
    }


def execute_workflow(name: str, target_id: str, target_name: str, x: int, y: int) -> dict:
    return {
        'parameters': {
            'workflowId': {
                '__rl': True,
                'value': target_id,
                'mode': 'list',
                'cachedResultUrl': f'/workflow/{target_id}',
                'cachedResultName': target_name,
            },
            'workflowInputs': {
                'mappingMode': 'defineBelow',
                'value': {},
                'matchingColumns': [],
                'schema': [],
                'attemptToConvertTypes': False,
                'convertFieldsToString': True,
            },
            'options': {'waitForSubWorkflow': True},
        },
        'type': 'n8n-nodes-base.executeWorkflow',
        'typeVersion': 1.3,
        'position': [x, y],
        'id': uid(name),
        'name': name,
        'onError': 'continueRegularOutput',
    }


def respond(name: str, x: int, y: int) -> dict:
    return {
        'parameters': {
            'respondWith': 'json',
            'responseBody': '={{ JSON.stringify($json.ok === false ? { ok:false, error:$json.error } : { ok:true, data:$json.data }) }}',
            'options': {'responseCode': '={{ $json.http_status || 200 }}'},
        },
        'type': 'n8n-nodes-base.respondToWebhook',
        'typeVersion': 1.4,
        'position': [x, y],
        'id': uid(name),
        'name': name,
    }


VERIFY = f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const item = $input.first();
const envelope = item.json || {{}};
const headers = envelope.headers || {{}};
const query = envelope.query || {{}};
const initData = headers["x-telegram-init-data"] || headers["X-Telegram-Init-Data"] || query.initData || query.init_data || null;
const auth = moneytrackVerifyTelegramInitData({{
  crypto,
  initData,
  botToken: $env.MONEYTRACK_BOT_TOKEN,
  maxAgeSeconds: $env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,
  maxFutureSkewSeconds: $env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS
}});
if (!auth.ok) return [{{ json: auth }}];
return [{{
  json: {{
    ok: true,
    telegram_user_id: auth.telegram_user_id,
    auth_contract_version: auth.auth_contract_version,
    body: envelope.body ?? null
  }},
  binary: item.binary || {{}}
}}];'''

USER_CONTEXT_QUERY = """select
    u.id::bigint as user_id,
    u.telegram_user_id::bigint as telegram_user_id,
    coalesce(s.language_code, u.language_code, 'en')::text as language_code,
    coalesce(u.language_code, s.language_code, 'en')::text as fallback_language_code,
    upper(coalesce(s.base_currency, u.default_currency, 'EUR'))::text as base_currency,
    upper(coalesce(s.report_currency, s.base_currency, u.default_currency, 'EUR'))::text as report_currency
from moneytrack.app_users u
left join moneytrack.user_settings s on s.user_id = u.id
where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
limit 1;"""

PHOTO_PREPARE = '''const auth = $('Photo Verify').first();
const user = $input.first().json || {};
const binary = auth.binary || {};
const fail = (code, http_status=400) => [{ json:{ ok:false, http_status, error:{code} } }];
if (!user.user_id) return fail('USER_NOT_FOUND', 404);
if (!Object.keys(binary).length) return fail('PHOTO_BINARY_MISSING');
return [{
  json: {
    ok: true,
    user_id: Number(user.user_id),
    telegram_user_id: Number(user.telegram_user_id),
    telegram_chat_id: null,
    message_caption: null,
    message_date: Math.floor(Date.now()/1000),
    message_type: 'photo',
    source_type: 'miniapp',
    language_code: user.language_code || 'en',
    fallback_language_code: user.fallback_language_code || user.language_code || 'en',
    base_currency: user.base_currency || 'EUR',
    report_currency: user.report_currency || user.base_currency || 'EUR',
    test_mode: false
  },
  binary
}];'''

TEXT_PREPARE = '''const auth = $('Text Verify').first();
const user = $input.first().json || {};
const fail = (code, http_status=400) => [{ json:{ ok:false, http_status, error:{code} } }];
if (!user.user_id) return fail('USER_NOT_FOUND', 404);
let body = auth.json?.body;
if (typeof body === 'string') {
  const raw = body.trim();
  if (raw.startsWith('{')) {
    try { body = JSON.parse(raw); } catch { body = raw; }
  }
}
const messageText = String(
  (body && typeof body === 'object' ? (body.text ?? body.message_text ?? '') : body) ?? ''
).trim();
if (!messageText) return fail('TEXT_REQUIRED');
return [{ json: {
  ok: true,
  user_id: Number(user.user_id),
  telegram_user_id: Number(user.telegram_user_id),
  telegram_chat_id: null,
  telegram_username: null,
  telegram_first_name: null,
  telegram_language_code: user.language_code || 'en',
  language_code: user.language_code || 'en',
  fallback_language_code: user.fallback_language_code || user.language_code || 'en',
  base_currency: user.base_currency || 'EUR',
  report_currency: user.report_currency || user.base_currency || 'EUR',
  message_text: messageText,
  message_caption: null,
  message_date: Math.floor(Date.now()/1000),
  message_type: 'text',
  source_type: 'miniapp',
  test_mode: false
} }];'''

VOICE_PREPARE = '''const auth = $('Voice Verify').first();
const user = $input.first().json || {};
const binary = auth.binary || {};
const fail = (code, http_status=400) => [{ json:{ ok:false, http_status, error:{code} } }];
if (!user.user_id) return fail('USER_NOT_FOUND', 404);
if (!Object.keys(binary).length) return fail('VOICE_BINARY_MISSING');
return [{
  json: {
    ok: true,
    user_id: Number(user.user_id),
    telegram_user_id: Number(user.telegram_user_id),
    telegram_chat_id: null,
    message_date: Math.floor(Date.now()/1000),
    message_type: 'voice',
    source_type: 'miniapp',
    language_code: user.language_code || 'en',
    fallback_language_code: user.fallback_language_code || user.language_code || 'en',
    base_currency: user.base_currency || 'EUR',
    report_currency: user.report_currency || user.base_currency || 'EUR',
    test_mode: false
  },
  binary
}];'''

VOICE_TO_TEXT = '''const voice = $input.first().json || {};
const user = $('Voice User Context').first().json || {};
const fail = (code, http_status=400) => [{ json:{ ok:false, http_status, error:{code} } }];
if (voice.error) return fail('VOICE_PROCESSOR_ERROR', 500);
const messageText = String(
  voice.voice_text ?? voice.message_text ?? voice.transcript ?? voice.text ?? voice.output_text ?? voice.output ?? ''
).trim();
if (!messageText) return fail('VOICE_TEXT_EMPTY');
return [{ json: {
  ok: true,
  user_id: Number(user.user_id),
  telegram_user_id: Number(user.telegram_user_id),
  telegram_chat_id: null,
  message_text: messageText,
  voice_text: messageText,
  message_type: 'text',
  source_type: 'voice',
  language_code: user.language_code || 'en',
  fallback_language_code: user.fallback_language_code || user.language_code || 'en',
  base_currency: user.base_currency || 'EUR',
  report_currency: user.report_currency || user.base_currency || 'EUR',
  test_mode: false
} }];'''

FORMAT = '''const row = $input.first().json || {};
if (row.error) {
  const raw = String(row.error?.message || row.error || 'DOMAIN_ERROR');
  const match = raw.match(/\\b([A-Z][A-Z0-9_]+)\\b/);
  return [{ json:{ ok:false, http_status:400, error:{ code:match ? match[1] : 'DOMAIN_ERROR' } } }];
}
return [{ json:{ ok:true, http_status:200, data:row } }];'''


def connect(connections: dict, source: str, targets: list[list[tuple[str, int]]]) -> None:
    connections[source] = {
        'main': [
            [{'node': node, 'type': 'main', 'index': index} for node, index in branch]
            for branch in targets
        ]
    }


def build(credential_id: str, credential_name: str) -> dict:
    nodes: list[dict] = []
    connections: dict = {}

    # Photo route.
    nodes.extend([
        webhook('Photo Webhook', 'api/v1/transaction/photo', -360),
        code('Photo Verify', VERIFY, -680, -360),
        if_node('Photo Auth OK', -470, -360),
        postgres('Photo User Context', USER_CONTEXT_QUERY, -260, -430, credential_id, credential_name),
        code('Photo Prepare', PHOTO_PREPARE, -40, -430),
        if_node('Photo Ready', 180, -430),
        execute_workflow('Photo Processor', PHOTO_PROCESSOR_ID, PHOTO_PROCESSOR_NAME, 400, -500),
        code('Photo Format', FORMAT, 620, -500),
        respond('Photo Respond', 850, -360),
    ])
    connect(connections, 'Photo Webhook', [[('Photo Verify', 0)]])
    connect(connections, 'Photo Verify', [[('Photo Auth OK', 0)]])
    connect(connections, 'Photo Auth OK', [[('Photo User Context', 0)], [('Photo Respond', 0)]])
    connect(connections, 'Photo User Context', [[('Photo Prepare', 0)]])
    connect(connections, 'Photo Prepare', [[('Photo Ready', 0)]])
    connect(connections, 'Photo Ready', [[('Photo Processor', 0)], [('Photo Respond', 0)]])
    connect(connections, 'Photo Processor', [[('Photo Format', 0)]])
    connect(connections, 'Photo Format', [[('Photo Respond', 0)]])

    # Text route.
    nodes.extend([
        webhook('Text Webhook', 'api/v1/transaction/text', 0),
        code('Text Verify', VERIFY, -680, 0),
        if_node('Text Auth OK', -470, 0),
        postgres('Text User Context', USER_CONTEXT_QUERY, -260, -70, credential_id, credential_name),
        code('Text Prepare', TEXT_PREPARE, -40, -70),
        if_node('Text Ready', 180, -70),
        execute_workflow('Text Processor', TEXT_PROCESSOR_ID, TEXT_PROCESSOR_NAME, 400, -140),
        code('Text Format', FORMAT, 620, -140),
        respond('Text Respond', 850, 0),
    ])
    connect(connections, 'Text Webhook', [[('Text Verify', 0)]])
    connect(connections, 'Text Verify', [[('Text Auth OK', 0)]])
    connect(connections, 'Text Auth OK', [[('Text User Context', 0)], [('Text Respond', 0)]])
    connect(connections, 'Text User Context', [[('Text Prepare', 0)]])
    connect(connections, 'Text Prepare', [[('Text Ready', 0)]])
    connect(connections, 'Text Ready', [[('Text Processor', 0)], [('Text Respond', 0)]])
    connect(connections, 'Text Processor', [[('Text Format', 0)]])
    connect(connections, 'Text Format', [[('Text Respond', 0)]])

    # Voice route: MiniApp binary -> Voice processor -> Text processor.
    nodes.extend([
        webhook('Voice Webhook', 'api/v1/transaction/voice', 360),
        code('Voice Verify', VERIFY, -680, 360),
        if_node('Voice Auth OK', -470, 360),
        postgres('Voice User Context', USER_CONTEXT_QUERY, -260, 290, credential_id, credential_name),
        code('Voice Prepare', VOICE_PREPARE, -40, 290),
        if_node('Voice Ready', 180, 290),
        execute_workflow('Voice Processor', VOICE_PROCESSOR_ID, VOICE_PROCESSOR_NAME, 400, 220),
        code('Voice To Text', VOICE_TO_TEXT, 620, 220),
        if_node('Voice Text Ready', 840, 220),
        execute_workflow('Voice Text Processor', TEXT_PROCESSOR_ID, TEXT_PROCESSOR_NAME, 1060, 150),
        code('Voice Format', FORMAT, 1280, 150),
        respond('Voice Respond', 1510, 360),
    ])
    connect(connections, 'Voice Webhook', [[('Voice Verify', 0)]])
    connect(connections, 'Voice Verify', [[('Voice Auth OK', 0)]])
    connect(connections, 'Voice Auth OK', [[('Voice User Context', 0)], [('Voice Respond', 0)]])
    connect(connections, 'Voice User Context', [[('Voice Prepare', 0)]])
    connect(connections, 'Voice Prepare', [[('Voice Ready', 0)]])
    connect(connections, 'Voice Ready', [[('Voice Processor', 0)], [('Voice Respond', 0)]])
    connect(connections, 'Voice Processor', [[('Voice To Text', 0)]])
    connect(connections, 'Voice To Text', [[('Voice Text Ready', 0)]])
    connect(connections, 'Voice Text Ready', [[('Voice Text Processor', 0)], [('Voice Respond', 0)]])
    connect(connections, 'Voice Text Processor', [[('Voice Format', 0)]])
    connect(connections, 'Voice Format', [[('Voice Respond', 0)]])

    return {
        'id': 'UX022QuickInput202608',
        'name': 'MoneyTrack MiniApp Quick Input API',
        'nodes': nodes,
        'connections': connections,
        'settings': {'executionOrder': 'v1'},
        'active': False,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--postgres-credential-id', default='tM27zg5m7tREo2ep')
    parser.add_argument('--postgres-credential-name', default='Postgres account')
    args = parser.parse_args()
    workflow = build(args.postgres_credential_id, args.postgres_credential_name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"quick_input={workflow['id']} nodes={len(workflow['nodes'])} path={args.output}")


if __name__ == '__main__':
    main()
