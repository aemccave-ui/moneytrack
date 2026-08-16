#!/usr/bin/env python3
"""Source-only gate for SPC-001F4 final acceptance polish."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "miniapp/src/main.jsx").read_text(encoding="utf-8")
APP = (ROOT / "miniapp/src/App.jsx").read_text(encoding="utf-8")
BASE = (ROOT / "miniapp/src/styles.css").read_text(encoding="utf-8")
POLISH = (ROOT / "miniapp/src/spc001-f4-acceptance-polish.css").read_text(encoding="utf-8")
QUICK = (ROOT / "miniapp/src/quick-actions-runtime.js").read_text(encoding="utf-8")
RUNNER = (ROOT / "scripts/spc001-f4r4-preview-apply.sh").read_text(encoding="utf-8")

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
    "f4_home_and_accounts_use_bottom_fixed_fab": (
        ".fabMenu { position:fixed" in BASE
        and ".spaceFinancialRoot .fabMenu" in POLISH
        and "position: fixed" in POLISH
        and "top: auto" in POLISH
        and "bottom: calc(96px + env(safe-area-inset-bottom))" in POLISH
        and "activeScreen === 'accounts'" in APP
        and APP.count("className={`fabMenu ${actionsOpen ? 'open' : ''}`}") >= 2
    ),
    "f4_home_last_transaction_clears_fixed_fab": all(x in POLISH for x in (
        ".spaceFinancialRoot > .app > .recentOperationsSection",
        "padding-bottom: 80px",
        "last transaction scroll fully above the FAB",
    )),
    "f4_rejected_inline_home_add_is_absent": all(x not in QUICK for x in (
        "homeQuickAddInline",
        "homeQuickInlineActions",
        "data-home-quick-action",
        "header.insertAdjacentElement('afterend', panel)",
        "homeQuickFabSource",
    )) and all(x not in POLISH for x in (
        ".homeQuickAddInline",
        ".homeQuickInlineActions",
        ".homeQuickFabSource",
        ".balanceHeader ~ .fabMenu",
    )),
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
    "f4_space_menu_matches_fab_palette": all(x in POLISH for x in (
        ".spaceManageButton",
        "linear-gradient(145deg, var(--mt-teal-800, #1d5559), var(--mt-teal-500, #4f9fa3))",
        "box-shadow: var(--mt-shadow-fab",
        "color: #fff",
    )),
    "f4r4_preview_requires_exact_f4_evidence_and_safe_delta": all(x in RUNNER for x in (
        "explicit_--apply_required",
        "SPC001_F4_PREVIEW=PASS",
        "sha256sum -c SHA256SUMS",
        "git merge-base --is-ancestor",
        "F4_TO_F4R4_SAFE_DELTA=PASS",
        "F4_CANONICAL_QUICK_ACTIONS_ALLOWED=PASS",
        "miniapp/src/quick-actions-runtime.js",
        "miniapp/src/spc001-f4-acceptance-polish.css",
    )) and (
        '[[ " ${CHANGED[*]} " == *" miniapp/src/spc001-f4-acceptance-polish.css "* ]]' in RUNNER
        and '[[ " ${CHANGED[*]} " == *" miniapp/src/quick-actions-runtime.js "* ]]' not in RUNNER
    ),
    "f4r4_preview_is_preview_only_with_rollback_and_identity": (
        RUNNER.index("npm run build") < RUNNER.index("preview_mutated=1")
        and RUNNER.index("preview.before.tgz") < RUNNER.index("rsync -a --delete")
        and "PREVIEW_ROLLBACK=PASS" in RUNNER
        and "PREVIEW_INDEX_IDENTITY=PASS" in RUNNER
        and "ASSET_IDENTITY=PASS" in RUNNER
        and "PREVIEW_ARTIFACT_IDENTITY=PASS" in RUNNER
        and "DB_MUTATION=NONE" in RUNNER
        and "N8N_MUTATION=NONE" in RUNNER
        and "PRODUCTION_FRONTEND_MUTATION=NONE" in RUNNER
        and "SPC001_F4R4_PREVIEW=PASS" in RUNNER
        and "docker exec" not in RUNNER
        and "psql" not in RUNNER
        and "n8n import:workflow" not in RUNNER
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
