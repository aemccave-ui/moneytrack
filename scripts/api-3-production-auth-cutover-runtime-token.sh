#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# The bot token is intentionally not required in the host-side n8n.env file.
# n8n itself already has the runtime secret, proven by API-3A. Import it into
# this process only so the signed freshness smoke can generate Telegram initData.
# Never print the value.
MONEYTRACK_BOT_TOKEN="$(docker exec n8n sh -lc 'printf %s "${MONEYTRACK_BOT_TOKEN:-}"' 2>/dev/null || true)"

if [ -z "$MONEYTRACK_BOT_TOKEN" ]; then
  echo "runtime_bot_token_import=FAIL"
  exit 1
fi

export MONEYTRACK_BOT_TOKEN
echo "runtime_bot_token_import=PASS token_not_printed=PASS"

exec bash scripts/api-3-production-auth-cutover.sh "$@"
