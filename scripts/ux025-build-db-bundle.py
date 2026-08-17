#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / 'db/domain/UX-025/010_space_category_directory.sql',
    ROOT / 'db/domain/UX-025/015_space_category_reorder.sql',
    ROOT / 'db/domain/UX-025/020_category_api_dispatch.sql',
]
TX = re.compile(r'^\s*(begin|commit|rollback)\s*;\s*$', re.I)


def inner(path: Path) -> str:
    lines = path.read_text(encoding='utf-8').splitlines()
    tx = [(i, TX.fullmatch(line).group(1).lower()) for i, line in enumerate(lines) if TX.fullmatch(line)]
    if [kind for _, kind in tx] != ['begin', 'commit']:
        raise SystemExit(f'UX025_DB_BUNDLE=FAIL transaction_shape path={path} tx={tx}')
    first, last = tx[0][0], tx[-1][0]
    if any(line.strip() for line in lines[:first]):
        # Header comments are allowed before BEGIN; executable SQL is not.
        for line in lines[:first]:
            stripped = line.strip()
            if stripped and not stripped.startswith('--'):
                raise SystemExit(f'UX025_DB_BUNDLE=FAIL executable_before_begin path={path}')
    return '\n'.join(lines[first + 1:last]).strip() + '\n'


def build(final: str) -> str:
    terminal = 'commit;' if final == 'commit' else 'rollback;'
    parts = [
        '-- MoneyTrack UX-025 atomic category directory bundle',
        '-- Generated; do not edit.',
        'begin;',
    ]
    for source in SOURCES:
        parts.extend([
            '',
            f'-- BEGIN SOURCE {source.relative_to(ROOT)}',
            inner(source).rstrip(),
            f'-- END SOURCE {source.relative_to(ROOT)}',
        ])
    parts.extend(['', terminal, ''])
    return '\n'.join(parts)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--final', choices=('commit', 'rollback'), required=True)
    args = parser.parse_args()
    payload = build(args.final)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(payload, encoding='utf-8')
    print(f'UX025_DB_BUNDLE=PASS final={args.final} bytes={len(payload.encode())} path={args.output}')


if __name__ == '__main__':
    main()
