#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/adm_mt/moneytrack"
ENV_FILE="/home/adm_mt/moneytrack-automation/config/n8n.env"
WORKFLOWS_DIR="$PROJECT_DIR/workflows"

mkdir -p "$WORKFLOWS_DIR"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

source "$ENV_FILE"

if [ -z "${N8N_BASE_URL:-}" ] || [ -z "${N8N_API_KEY:-}" ]; then
  echo "N8N_BASE_URL or N8N_API_KEY is not set"
  exit 1
fi

echo "Exporting n8n workflows from $N8N_BASE_URL"

response_file="$(mktemp)"

curl -sS \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "$N8N_BASE_URL/api/v1/workflows" \
  > "$response_file"

if ! jq -e '.data' "$response_file" >/dev/null; then
  echo "Invalid n8n API response"
  cat "$response_file"
  rm -f "$response_file"
  exit 1
fi

jq -c '.data[]' "$response_file" | while read -r workflow; do
  id="$(echo "$workflow" | jq -r '.id')"
  name="$(echo "$workflow" | jq -r '.name')"

  slug="$(echo "$name" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

  file="$WORKFLOWS_DIR/${slug}-${id}.json"

  echo "$workflow" | jq . > "$file"

  echo "exported $file"
done

rm -f "$response_file"

cd "$PROJECT_DIR"

if [ ! -d ".git" ]; then
  git init
  git branch -M main
fi

if [ ! -f ".gitignore" ]; then
  cat > .gitignore <<'GITIGNORE'
.env
.env.*
node_modules/
logs/
*.log
tmp/
backup/
backups/
*.zip
*.tar.gz
GITIGNORE
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin git@github.com:aemccave-ui/moneytrack.git
fi

if [ -n "$(git status --short)" ]; then
  git add .
  git commit -m "workflow: export n8n workflows"
  git push -u origin main
else
  echo "No workflow changes to commit"
fi

echo "Workflow export completed"
