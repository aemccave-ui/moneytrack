#!/usr/bin/env python3
"""Run the accepted UX-022 source verifier across the UX-025 screen boundary.

UX-025 intentionally moves Home and Accounts JSX out of App.jsx. The accepted
UX-022 verifier contains a few structural assertions that historically inspect
App.jsx for those screen-local tokens. Rather than weakening or duplicating the
legacy verifier, execute it unchanged while adapting only its `app` source
surface to App + HomeScreen + AccountsScreen.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts/ux022-verify-source.py"

source = VERIFIER.read_text(encoding="utf-8")
needle = 'app = read("miniapp/src/App.jsx")\n'
replacement = (
    'app = "\\n".join((\n'
    '    read("miniapp/src/App.jsx"),\n'
    '    read("miniapp/src/screens/HomeScreen.jsx"),\n'
    '    read("miniapp/src/screens/AccountsScreen.jsx"),\n'
    '))\n'
)

if source.count(needle) != 1:
    raise SystemExit("UX025_UX022_COMPAT=FAIL accepted verifier app binding changed")

adapted = source.replace(needle, replacement, 1)
namespace = {
    "__name__": "__main__",
    "__file__": str(VERIFIER),
}
exec(compile(adapted, str(VERIFIER), "exec"), namespace)
print("UX025_UX022_SCREEN_DECOMPOSITION_COMPAT=PASS")
