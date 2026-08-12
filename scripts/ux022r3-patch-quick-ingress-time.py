#!/usr/bin/env python3
"""Preserve MiniApp voice ingress time when Voice is delegated to Text processor.

The Quick Input workflow already stamps Voice Prepare with message_date. The
Voice To Text adapter historically dropped that field, so the downstream Text
processor could only fall back to its execution clock. This transformer copies
that original ingress epoch into the Text-shaped payload without changing graph
topology or any other node.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = 'UX022QuickInput202608'
VOICE_TO_TEXT = 'Voice To Text'

MESSAGE_DATE_LINE = "  message_date: Number($('Voice Prepare').first().json.message_date || Math.floor(Date.now()/1000)),\n"
ANCHOR = "  message_type: 'text',\n"


def load(path: Path):
    document = json.loads(path.read_text(encoding='utf-8'))
    if isinstance(document, list):
        if len(document) != 1:
            raise SystemExit(f'ERROR: expected one workflow in {path}, found {len(document)}')
        return document, document[0]
    if isinstance(document, dict):
        return document, document
    raise SystemExit(f'ERROR: invalid workflow document {path}')


def node(workflow: dict, name: str) -> dict:
    rows = [item for item in workflow.get('nodes', []) if item.get('name') == name]
    if len(rows) != 1:
        raise SystemExit(f'ERROR: expected exactly one {name!r}, found {len(rows)}')
    return rows[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()

    document, workflow = load(args.source)
    if str(workflow.get('id')) != WORKFLOW_ID:
        raise SystemExit(f"ERROR: unexpected workflow id {workflow.get('id')!r}")

    text_prepare = str((node(workflow, 'Text Prepare').get('parameters') or {}).get('jsCode', ''))
    voice_prepare = str((node(workflow, 'Voice Prepare').get('parameters') or {}).get('jsCode', ''))
    for name, code in [('Text Prepare', text_prepare), ('Voice Prepare', voice_prepare)]:
        if 'message_date:' not in code:
            raise SystemExit(f'ERROR: {name} does not provide message_date')

    target = node(workflow, VOICE_TO_TEXT)
    if target.get('type') != 'n8n-nodes-base.code':
        raise SystemExit(f'ERROR: {VOICE_TO_TEXT!r} is not a Code node')
    before_code = str((target.get('parameters') or {}).get('jsCode', ''))

    already = "$('Voice Prepare').first().json.message_date" in before_code
    if already:
        after_code = before_code
    else:
        if before_code.count(ANCHOR) != 1:
            raise SystemExit(f'ERROR: Voice To Text anchor count={before_code.count(ANCHOR)}, expected 1')
        after_code = before_code.replace(ANCHOR, MESSAGE_DATE_LINE + ANCHOR, 1)

    out = copy.deepcopy(document)
    out_workflow = out[0] if isinstance(out, list) else out
    out_target = node(out_workflow, VOICE_TO_TEXT)
    out_target.setdefault('parameters', {})['jsCode'] = after_code

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(out, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    if "$('Voice Prepare').first().json.message_date" not in str(out_target['parameters']['jsCode']):
        raise SystemExit('ERROR: candidate does not preserve Voice Prepare message_date')

    print(f'quick_ingress_candidate={args.output}')
    print(f'changed_node={VOICE_TO_TEXT}')
    print('voice_ingress_time=' + ('ALREADY_PRESENT' if already else 'PATCHED'))
    print('graph_topology=UNCHANGED')
    print('status=PASS')


if __name__ == '__main__':
    main()
