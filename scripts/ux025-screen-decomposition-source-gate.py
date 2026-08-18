#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


screen_paths = {
    'home': 'miniapp/src/screens/HomeScreen.jsx',
    'accounts': 'miniapp/src/screens/AccountsScreen.jsx',
    'budgets': 'miniapp/src/screens/BudgetsScreen.jsx',
    'stats': 'miniapp/src/screens/StatisticsScreen.jsx',
    'settings': 'miniapp/src/screens/SettingsScreen.jsx',
}

app = read('miniapp/src/App.jsx')
main = read('miniapp/src/main.jsx')
settings = read(screen_paths['settings'])
settings_css = read('miniapp/src/screens/ux025-screens.css')
settings_compat = read('miniapp/src/SettingsPortal.jsx')
category_settings = read('miniapp/src/screens/settings/CategorySettings.jsx')
category_editor = read('miniapp/src/screens/settings/CategoryEditor.jsx')
category_tree = read('miniapp/src/screens/settings/CategoryTree.jsx')
category_api = read('miniapp/src/category-directory-api.js')
workflow = read('.github/workflows/moneytrack-source-gates.yml')
preview_apply_path = ROOT / 'scripts/ux025-preview-runtime-apply.sh'
preview_apply = preview_apply_path.read_text(encoding='utf-8')

checks = {
    'ux025_top_level_screen_files_exist': all((ROOT / path).is_file() for path in screen_paths.values()),
    'ux025_app_imports_all_screen_boundaries': all(
        f"./screens/{Path(path).name}" in app for path in screen_paths.values()
    ),
    'ux025_all_bottom_navigation_ids_are_routable': all(
        token in app for token in (
            "{ id: 'home'",
            "{ id: 'accounts'",
            "{ id: 'budgets'",
            "{ id: 'stats'",
            "{ id: 'settings'",
            "() => openScreen(item.id)",
        )
    ),
    'ux025_app_is_screen_orchestrator': (
        'SettingsPortal' not in app
        and "import SettingsScreen from './screens/SettingsScreen.jsx'" in app
        and "activeScreen === 'settings'" in app
    ),
    'ux025_sec001_compatibility_marker_is_inert': (
        'SettingsPortal' in main
        and 'return null' in settings_compat
        and 'document.' not in settings_compat
        and 'fetch(' not in settings_compat
        and 'getTransactionReference' not in settings_compat
        and 'useEffect' not in settings_compat
    ),
    'ux025_settings_is_real_navigation_screen': (
        "activeScreen === 'settings'" in app
        and '<SettingsScreen navigation={navigation} />' in app
        and 'LabBottomNavigation' in settings
        and 'activeId="settings"' in settings
    ),
    'ux025_settings_sections_collapsed_by_default': all(token in settings for token in (
        'const [openSection, setOpenSection] = useState(null)',
        'Управление защитой',
        'Управление категориями',
        "openSection === 'security'",
        "openSection === 'categories'",
        'current === section ? null : section',
    )),
    'ux025_settings_has_no_dom_text_interceptor': all(token not in settings for token in (
        'document.addEventListener',
        "textContent?.trim()",
        "includes('Настройки')",
    )),
    'ux025_security_component_preserved': "import SecuritySettings from '../SecuritySettings.jsx'" in settings,
    'ux025_category_screen_is_composed_not_inline_table': (
        "import CategorySettings from './settings/CategorySettings.jsx'" in settings
        and '<CategorySettings />' in settings
        and 'CategorySettingsRow' not in settings
        and 'updateCategory' not in settings
    ),
    'ux025_category_crud_client_complete': all(token in category_api for token in (
        'getCategoryDirectory',
        'createCategory',
        'editCategory',
        'reorderCategory',
        'deleteCategory',
        "'X-MoneyTrack-Space-Id'",
        "'X-MoneyTrack-Unlock-Token'",
        "moneytrack:space-invalid",
        "moneytrack:locked",
    )),
    'ux025_category_ui_has_create_edit_reparent_reorder_delete': all(token in (category_settings + category_editor + category_tree) for token in (
        '+ Добавить',
        'createCategory',
        'editCategory',
        'parentId',
        'reorderCategory',
        "onMove(category, 'up')",
        "onMove(category, 'down')",
        'deleteCategory',
        'CategoryEditor',
        'CategoryTree',
    )),
    'ux025_category_editor_excludes_self_and_descendants': all(token in category_editor for token in (
        'blockedParentIds',
        'new Set([String(category.id)])',
        'children.get(id)',
        '!blockedParentIds.has(String(item.id))',
    )),
    'ux025_category_directory_owns_vertical_scroll': all(token in settings_css for token in (
        '.categoryTree {',
        'max-height: clamp(260px, 44dvh, 520px)',
        'overflow-x: hidden',
        'overflow-y: auto',
        'overscroll-behavior-y: contain',
        '-webkit-overflow-scrolling: touch',
        'touch-action: pan-y',
        'scrollbar-gutter: stable',
        '.categoryTreeRow button {',
    )),
    'ux025_preview_apply_is_fail_closed': all(token in preview_apply for token in (
        'MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview',
        '--db-evidence-dir',
        '--n8n-evidence-dir',
        'UX025_DB_EVIDENCE=PASS',
        'UX025_N8N_EVIDENCE=PASS',
        'git merge-base --is-ancestor "$N8N_EVIDENCE_HEAD" "$HEAD_SHA"',
        'git diff --quiet "$N8N_EVIDENCE_HEAD" "$HEAD_SHA"',
        'npm run lint',
        'npm run build',
        'preview.before.tgz',
        'rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"',
        'UX025_PREVIEW_INDEX_IDENTITY=PASS',
        'UX025_PREVIEW_ARTIFACT_IDENTITY=PASS',
        'PRODUCTION_FRONTEND_MUTATION=NONE',
        'UX025_PREVIEW_APPLY=PASS',
    )),
    'ux025_gate_is_wired_into_source_ci': 'python3 scripts/ux025-screen-decomposition-source-gate.py' in workflow,
}

try:
    subprocess.run(['bash', '-n', str(preview_apply_path)], check=True, cwd=ROOT, stdout=subprocess.DEVNULL)
    checks['ux025_preview_apply_shell_syntax'] = True
except Exception:
    checks['ux025_preview_apply_shell_syntax'] = False

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"UX025_SCREEN_DECOMPOSITION_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print('DB_MUTATION=NONE')
print('N8N_MUTATION=NONE')
print('PREVIEW_MUTATION=NONE')
print('PRODUCTION_FRONTEND_MUTATION=NONE')
sys.exit(1 if failed else 0)
