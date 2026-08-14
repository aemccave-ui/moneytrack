#!/usr/bin/env python3
"""Patch the active Photo processor to extract and preserve receipt clock time.

This transformer is intentionally pinned to the exact runtime prompt/parser hashes
observed by UX-022R3 deep forensic. If runtime drifts, it fails closed instead of
editing an unknown AI contract.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path

WORKFLOW_ID = '5VC0EcFB21rwTfoI'
PROMPT_NODE = 'Analyze image'
PARSE_NODE = 'Parse receipt JSON'
EXPECTED_PROMPT_SHA256 = '5bca0e955b61cc8b56036826dce54d78b1b6bf627f571cc36680466eb3778e24'
EXPECTED_PARSE_SHA256 = '7a4edfeffc24e33489a8888ade66c02146cb81055495efebe19102c2867bec6f'

PROMPT = '''Extract receipt data from image.

Return only valid JSON.
No markdown.
Do not truncate JSON.
Use null for unknown values.

Fields:
shop_name,
receipt_date,
receipt_time,
total_amount,
currency,
items.

Each item:
item_name_original,
item_language,
quantity,
unit_price,
amount.

Rules:

- receipt_date must be the calendar date printed on the receipt when visible.
- receipt_time must be the clock time printed on the receipt in 24h HH:MM or HH:MM:SS format; use null when no receipt clock is visible.
- Never invent receipt_time from image metadata, current time, or processing time.
- item_language must be ISO 639-1 language code.
- Allowed values:
  en, ru, es, fr, de, kk, pt, it.
- Never return language names.
- Return "es" instead of "Spanish".
- Return "ru" instead of "Russian".
- Return "en" instead of "English".
- Preserve item_name_original exactly as printed on the receipt.'''

PARSE_JS = r'''const input = $input.first().json;

function collectText(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(collectText).filter(Boolean).join('\n');
  if (typeof value === 'object') {
    const candidates = [
      value.content,
      value.text,
      value.output,
      value.response,
      value.message,
      value.data
    ];
    return candidates.map(collectText).filter(Boolean).join('\n');
  }
  return String(value);
}

function normalizeDate(value) {
  if (!value) return null;
  const s = String(value).trim();

  const iso = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[T\s].*)?$/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;

  const dmy = s.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{4})(?:\s+.*)?$/);
  if (dmy) {
    const dd = dmy[1].padStart(2, '0');
    const mm = dmy[2].padStart(2, '0');
    return `${dmy[3]}-${mm}-${dd}`;
  }

  const ymd = s.match(/^(\d{4})[./](\d{1,2})[./](\d{1,2})(?:\s+.*)?$/);
  if (ymd) {
    const mm = ymd[2].padStart(2, '0');
    const dd = ymd[3].padStart(2, '0');
    return `${ymd[1]}-${mm}-${dd}`;
  }

  return s;
}

function normalizeTime(value) {
  if (!value) return null;
  const s = String(value).trim();
  const match = s.match(/(?:^|[T\s])([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?:\s|$)/)
    || s.match(/^([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?$/);
  if (!match) return null;
  const hh = match[1].padStart(2, '0');
  const mm = match[2];
  const ss = match[3] || null;
  return ss ? `${hh}:${mm}:${ss}` : `${hh}:${mm}`;
}

let content = collectText(input).trim();
content = content
  .replace(/^```json\s*/i, '')
  .replace(/^```\s*/i, '')
  .replace(/```$/i, '')
  .trim();

const firstBrace = content.indexOf('{');
const lastBrace = content.lastIndexOf('}');
if (firstBrace >= 0 && lastBrace > firstBrace) {
  content = content.slice(firstBrace, lastBrace + 1);
}

let parsed;
try {
  parsed = JSON.parse(content);
} catch (e) {
  return [{
    json: {
      parse_error: true,
      error_message: e.message,
      raw_content: content
    }
  }];
}

const rawDate = parsed.receipt_datetime || parsed.receipt_date || parsed.transaction_date || parsed.date || null;
const normalizedDate = normalizeDate(rawDate);
const normalizedTime = normalizeTime(
  parsed.receipt_time ||
  parsed.time ||
  parsed.receipt_datetime ||
  rawDate
);
const trigger = $('MoneyTrack Transaction Processor Photo').first().json;

return [{
  json: {
    ...trigger,
    ...parsed,
    receipt_date: normalizedDate,
    receipt_time: normalizedTime,
    transaction_date: normalizedDate,
    parse_error: false
  }
}];'''


def sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def load(path: Path):
    document = json.loads(path.read_text(encoding='utf-8'))
    if isinstance(document, list):
        if len(document) != 1:
            raise SystemExit(f'ERROR: expected one workflow, found {len(document)}')
        return document, document[0]
    if isinstance(document, dict):
        return document, document
    raise SystemExit('ERROR: invalid workflow JSON')


def one_node(workflow: dict, name: str) -> dict:
    rows = [node for node in workflow.get('nodes', []) if node.get('name') == name]
    if len(rows) != 1:
        raise SystemExit(f'ERROR: expected one {name!r}, found {len(rows)}')
    return rows[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()

    document, workflow = load(args.source)
    if str(workflow.get('id')) != WORKFLOW_ID:
        raise SystemExit(f"ERROR: unexpected workflow id {workflow.get('id')!r}")

    prompt_node = one_node(workflow, PROMPT_NODE)
    parse_node = one_node(workflow, PARSE_NODE)
    prompt_before = str((prompt_node.get('parameters') or {}).get('text', ''))
    parse_before = str((parse_node.get('parameters') or {}).get('jsCode', ''))

    if sha(prompt_before) != EXPECTED_PROMPT_SHA256:
        raise SystemExit(f'ERROR: Analyze image prompt drift sha256={sha(prompt_before)}')
    if sha(parse_before) != EXPECTED_PARSE_SHA256:
        raise SystemExit(f'ERROR: Parse receipt JSON drift sha256={sha(parse_before)}')

    out = copy.deepcopy(document)
    out_workflow = out[0] if isinstance(out, list) else out
    out_prompt = one_node(out_workflow, PROMPT_NODE)
    out_parse = one_node(out_workflow, PARSE_NODE)
    out_prompt.setdefault('parameters', {})['text'] = PROMPT
    out_parse.setdefault('parameters', {})['jsCode'] = PARSE_JS

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(out, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    print(f'photo_receipt_clock_candidate={args.output}')
    print(f'changed_nodes={PROMPT_NODE},{PARSE_NODE}')
    print('receipt_time_contract=explicit_24h_field_null_when_absent')
    print('receipt_time_invention=FORBIDDEN')
    print('graph_topology=UNCHANGED')
    print('status=PASS')


if __name__ == '__main__':
    main()
