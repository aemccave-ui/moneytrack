#!/usr/bin/env python3
"""Source-only gate for SPC-001F4.2 acceptance polish."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "miniapp/src/main.jsx").read_text(encoding="utf-8")
APP = (ROOT / "miniapp/src/App.jsx").read_text(encoding="utf-8")
BASE = (ROOT / "miniapp/src/styles.css").read_text(encoding="utf-8")
POLISH = (ROOT / "miniapp/src/spc001-f4-acceptance-polish.css").read_text(encoding="utf-8")
QUICK = (ROOT / "miniapp/src/quick-actions-runtime.js").read_text(encoding="utf-8")

checks = {
    "f4_recovery_notice_is_transient": all(x in POLISH for x in (
        ".spaceGateNotice",
        "animation: spc001SpaceNoticeDismiss .32s ease 5s forwards",
        "max-height: 0",
        "margin-bottom: 0",
        "visibility: hidden",
        "pointer-events: none",
    )),
    "f4_polish_loads_after_space_contract_css": (
        "import './spc001-space.css'" in MAIN
        and "import './spc001-f4-acceptance-polish.css'" in MAIN
        and MAIN.index("import './spc001-space.css'") < MAIN.index("import './spc001-f4-acceptance-polish.css'")
    ),
    "f4_home_quick_add_is_not_viewport_fab": (
        "menu?.classList.add('homeQuickFabSource')" in QUICK
        and ".homeQuickFabSource" in POLISH
        and "display: none !important" in POLISH
        and ".balanceHeader ~ .fabMenu" not in POLISH
    ),
    "f4_home_quick_add_is_docked_to_recent_operations": all(x in QUICK for x in (
        "document.querySelector('.recentOperationsSection > .sectionHeader')",
        "homeQuickAddInline",
        "header.appendChild(button)",
        "aria-label', 'Добавить операцию'",
    )) and all(x in POLISH for x in (
        ".recentOperationsSection > .sectionHeader",
        ".homeQuickAddInline",
        "margin-left: auto",
    )),
    "f4_home_quick_actions_expand_in_normal_flow": all(x in QUICK for x in (
        "homeQuickInlineActions",
        "header.insertAdjacentElement('afterend', panel)",
        "data-home-quick-action",
    )) and all(x in POLISH for x in (
        ".homeQuickInlineActions",
        "display: grid",
        "grid-template-columns: repeat(2, minmax(0, 1fr))",
    )) and "position: fixed" not in POLISH,
    "f4_home_quick_action_capabilities_preserved": all(x in QUICK for x in (
        "moneytrack:new-operation",
        "photoInput.click()",
        "openText()",
        "openAudio()",
        "Операция",
        "Фото чека",
        "Голос",
        "Текст",
    )),
    "f4_accounts_fab_contract_preserved": (
        ".fabMenu { position:fixed" in BASE
        and "activeScreen === 'accounts'" in APP
        and "className={`fabMenu ${actionsOpen ? 'open' : ''}`}" in APP
        and "const isHomeQuickMenu = labels.some" in QUICK
        and "['Фото', 'Фото чека', 'Текст', 'Голос']" in QUICK
    ),
}

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"SPC001_F4_ACCEPTANCE_POLISH_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_EVIDENCE=NOT_CLAIMED")
print("DB_MUTATION=NONE")
print("N8N_MUTATION=NONE")
print("PREVIEW_MUTATION=NONE")
print("PRODUCTION_FRONTEND_MUTATION=NONE")
sys.exit(1 if failed else 0)
