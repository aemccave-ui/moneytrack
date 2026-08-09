#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

N8N_BASE="/root/stack/n8n/docker-compose.yml"
MT_BASE="/opt/moneytrack/postgres/docker-compose.yml"
N8N_WORKDIR="/root/stack/n8n"
MT_WORKDIR="/opt/moneytrack/postgres"
N8N_SNAPSHOT="/root/stack/n8n/compose-interpolation.prod-h.sh"
MT_SNAPSHOT="/opt/moneytrack/postgres/compose-interpolation.prod-h.sh"
MARKER="# moneytrack-prod-h3-compose-interpolation-v1"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required_command_missing=$1"
    exit 1
  }
}

for c in docker grep sed sort awk install mktemp; do
  require "$c"
done

docker compose version >/dev/null 2>&1 || {
  echo "docker_compose_plugin=FAIL"
  exit 1
}

TMP="$(mktemp -d /tmp/moneytrack-prod-h3-compose-context.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
umask 077

project_containers() {
  local project="$1"
  docker ps -a \
    --filter "label=com.docker.compose.project=$project" \
    --format '{{.Names}}' \
    | sort -u
}

compose_probe() {
  local workdir="$1" project="$2" base="$3" err="$4"
  local rc=0
  (
    cd "$workdir"
    docker compose -p "$project" -f "$base" config >/dev/null 2>"$err"
  ) || rc=$?
  return "$rc"
}

missing_vars_from_err() {
  local err="$1"
  sed -n 's/.*The "\([A-Za-z_][A-Za-z0-9_]*\)" variable is not set.*/\1/p' "$err" \
    | sort -u
}

recover_runtime_value() {
  local var="$1"
  shift
  local c line value="" found=0 current

  for c in "$@"; do
    line="$(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | grep -m1 -F "${var}=" || true)"

    if [ -n "$line" ] && [ "${line%%=*}" = "$var" ]; then
      current="${line#*=}"
      if [ "$found" -eq 0 ]; then
        value="$current"
        found=1
      elif [ "$value" != "$current" ]; then
        echo "compose_interpolation_runtime_conflict=FAIL var=$var containers_disagree=true"
        return 1
      fi
    fi
  done

  if [ "$found" -eq 0 ]; then
    echo "compose_interpolation_runtime_source=FAIL var=$var"
    return 1
  fi

  RECOVERED_VALUE="$value"
  return 0
}

capture_project_context() {
  local name="$1" workdir="$2" project="$3" base="$4" snapshot="$5"
  local err="$TMP/${name}.probe.err"
  local staged="$TMP/${name}.snapshot.sh"
  local -a containers=()
  local -a vars=()
  local var

  [ -d "$workdir" ] || { echo "$name compose_workdir=FAIL path=$workdir"; return 1; }
  [ -f "$base" ] || { echo "$name compose_base=FAIL path=$base"; return 1; }

  if [ -e "$snapshot" ] && ! grep -Fxq "$MARKER" "$snapshot"; then
    echo "$name existing_interpolation_snapshot=UNMANAGED path=$snapshot"
    return 1
  fi

  mapfile -t containers < <(project_containers "$project")
  [ "${#containers[@]}" -gt 0 ] || {
    echo "$name compose_project_containers=FAIL project=$project"
    return 1
  }

  compose_probe "$workdir" "$project" "$base" "$err" || true
  mapfile -t vars < <(missing_vars_from_err "$err")

  {
    echo "$MARKER"
    echo "# Captured from the live production container environment."
    echo "# Values are intentionally not printed by the installer or gates."
  } > "$staged"

  for var in "${vars[@]}"; do
    recover_runtime_value "$var" "${containers[@]}"
    printf 'export %s=%q\n' "$var" "$RECOVERED_VALUE" >> "$staged"
  done

  install -m 0600 "$staged" "$snapshot"

  # shellcheck disable=SC1090
  source "$snapshot"

  : > "$err"
  if ! compose_probe "$workdir" "$project" "$base" "$err"; then
    echo "$name compose_context_validation=FAIL"
    sed 's/^/  /' "$err" | head -n 20
    return 1
  fi

  if grep -Fq 'variable is not set' "$err"; then
    echo "$name compose_context_validation=FAIL unresolved_interpolation=true"
    sed 's/^/  /' "$err" | head -n 20
    return 1
  fi

  echo "$name compose_interpolation_snapshot=PASS path=$snapshot mode=$(stat -c '%a' "$snapshot") recovered_vars=${#vars[@]} values_not_printed=PASS"
  if [ "${#vars[@]}" -gt 0 ]; then
    printf '%s recovered_interpolation_vars=' "$name"
    printf '%s ' "${vars[@]}"
    printf '\n'
  fi
}

N8N_PROJECT="$(docker inspect n8n --format '{{index .Config.Labels "com.docker.compose.project"}}')"
MT_PROJECT="$(docker inspect moneytrack-db --format '{{index .Config.Labels "com.docker.compose.project"}}')"
[ -n "$N8N_PROJECT" ] && [ -n "$MT_PROJECT" ] || {
  echo "compose_project_resolution=FAIL"
  exit 1
}

echo "=== PROD-H3 COMPOSE CONTEXT RECOVERY START ==="

capture_project_context n8n "$N8N_WORKDIR" "$N8N_PROJECT" "$N8N_BASE" "$N8N_SNAPSHOT"
capture_project_context moneytrack "$MT_WORKDIR" "$MT_PROJECT" "$MT_BASE" "$MT_SNAPSHOT"

# Re-source both snapshots into the parent wrapper environment so child preflight/cutover
# inherit exactly the recovered interpolation variables without printing values.
# shellcheck disable=SC1090
source "$N8N_SNAPSHOT"
# shellcheck disable=SC1090
source "$MT_SNAPSHOT"

echo "compose_context_recovery=PASS values_not_printed=PASS"

echo
echo "=== PROD-H3 WRAPPED PREFLIGHT ==="
bash "$SCRIPT_DIR/prod-h3-runtime-hardening-preflight.sh"

echo
echo "=== PROD-H3 WRAPPED CUTOVER ==="
bash "$SCRIPT_DIR/prod-h3-runtime-hardening-cutover.sh"

echo "=== PROD-H3 COMPOSE CONTEXT WRAPPER PASS ==="
