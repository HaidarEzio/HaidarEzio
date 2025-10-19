#!/usr/bin/env bash
# Forgejo bulk migration from GitHub (macOS-safe, resume-friendly)
# - Supports FORCE_REMIGRATE (delete & re-import)
# - Triggers mirror-sync and waits until content arrives (or times out)
# - Skips forks/archived optionally; handles private/public
# - Works on macOS bash 3 (no ${var,,})

set -euo pipefail

########################################
# CONFIG (env overrides supported)
########################################
FORGEJO_BASE="${FORGEJO_BASE:-https://forgejo.haidarezio.me}"
FORGEJO_OWNER="${FORGEJO_OWNER:-haidarezio}"

# Behavior
INCLUDE_FORKS="${INCLUDE_FORKS:-false}"    # true => include forks
ONLY_PRIVATE="${ONLY_PRIVATE:-false}"       # true => migrate only private
SKIP_ARCHIVED="${SKIP_ARCHIVED:-true}"      # true => skip archived
MODE="${MODE:-mirror}"                      # mirror | copy
MIRROR_INTERVAL="${MIRROR_INTERVAL:-8h0m0s}"

# Re-import behavior
FORCE_REMIGRATE="${FORCE_REMIGRATE:-false}" # true => delete existing then re-import
DRY_RUN="${DRY_RUN:-false}"                 # true => show deletions only

# Post-migrate waiting
SYNC_TIMEOUT_SEC="${SYNC_TIMEOUT_SEC:-180}" # how long to wait for content (per repo)
SYNC_POLL_SEC="${SYNC_POLL_SEC:-4}"         # poll interval

# Required tokens (export these before running)
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN (GitHub PAT with repo scope)}"
: "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN (Forgejo PAT)}"

########################################
# Helpers
########################################
lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
exists_in_path() { command -v "$1" >/dev/null 2>&1; }
require() { exists_in_path "$1" || { echo "Please install $1"; exit 1; }; }

require gh; require jq; require curl

# Detect GitHub username for auth_username (can override with env)
GITHUB_USERNAME="${GITHUB_USERNAME:-$(gh api user -q .login 2>/dev/null || true)}"
GITHUB_USERNAME="${GITHUB_USERNAME:-}" # defined even if empty

# Migrate endpoint probe (POST; 422 is expected with empty body)
printf "Forgejo migrate endpoint: "
probe_code="$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST -H "Authorization: token ${FORGEJO_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' "${FORGEJO_BASE}/api/v1/repos/migrate")"
echo "HTTP ${probe_code}"

# GET repo JSON (0 on success + prints JSON; 1 if not exist)
get_repo_json() {
  local nm_lc; nm_lc="$(lower "${1:-}")"
  local resp code body
  resp="$(curl -sS -w $'\n%{http_code}' \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_BASE}/api/v1/repos/${FORGEJO_OWNER}/${nm_lc}")" || true
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [ "$code" = "200" ]; then printf '%s\n' "$body"; return 0; fi
  return 1
}

delete_repo() {
  local nm_lc; nm_lc="$(lower "${1:-}")"
  if [ "$DRY_RUN" = "true" ]; then
    echo "DRY_RUN: would delete ${FORGEJO_OWNER}/${nm_lc}"
    return 0
  fi
  curl -sS -f -X DELETE \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_BASE}/api/v1/repos/${FORGEJO_OWNER}/${nm_lc}" >/dev/null
}

# call migrate API; prints "<code>\n<body>"
api_migrate() {
  local payload="${1:-{}}"
  local resp; resp="$(curl -sS -w $'\n%{http_code}' \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d "$payload" \
    "${FORGEJO_BASE}/api/v1/repos/migrate")"
  local code body
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  printf '%s\n' "$code" "$body"
}

# trigger mirror sync
mirror_sync_now() {
  local name_lc; name_lc="$(lower "${1:-}")"
  curl -s -X POST -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_BASE}/api/v1/repos/${FORGEJO_OWNER}/${name_lc}/mirror-sync" >/dev/null
}

# wait until repo has content or timeout
wait_for_content() {
  local name="$1"
  local name_lc; name_lc="$(lower "$name")"
  local waited=0

  while [ "$waited" -lt "$SYNC_TIMEOUT_SEC" ]; do
    local js empty size
    if js="$(get_repo_json "$name_lc")"; then
      empty="$(jq -r '.empty // false' <<<"$js")"
      size="$(jq -r '.size // 0' <<<"$js")"
      if [ "$empty" = "false" ] && [ "$size" != "0" ]; then
        echo "   ↳ content present (size=$size)"
        return 0
      fi
    fi
    # kick a sync and wait a bit
    mirror_sync_now "$name_lc"
    sleep "$SYNC_POLL_SEC"
    waited=$(( waited + SYNC_POLL_SEC ))
  done

  echo "   ↳ timeout waiting for content"
  return 1
}

migrate_one() {
  # args: full_name isPrivate description isFork isArchived
  local full_name="${1:-}"
  local is_private="${2:-false}"
  local description="${3:-}"
  local is_fork="${4:-false}"
  local is_archived="${5:-false}"

  if [ -z "$full_name" ]; then
    echo "Skipping empty record"; return 0
  fi

  local name="${full_name##*/}"
  local name_lc; name_lc="$(lower "$name")"

  # filters
  if [ "$is_fork" = "true" ] && [ "$INCLUDE_FORKS" != "true" ]; then
    echo "Skipping fork $full_name"; return 0; fi
  if [ "$SKIP_ARCHIVED" = "true" ] && [ "$is_archived" = "true" ]; then
    echo "Skipping archived $full_name"; return 0; fi
  if [ "$ONLY_PRIVATE" = "true" ] && [ "$is_private" != "true" ]; then
    echo "Skipping public $full_name (ONLY_PRIVATE=true)"; return 0; fi

  # if exists: either skip or delete for re-import
  if repo_json="$(get_repo_json "$name_lc")"; then
    if [ "$FORCE_REMIGRATE" = "true" ]; then
      is_mirror="$(jq -r '.mirror // false' <<<"$repo_json")"
      size_val="$(jq -r '.size // 0' <<<"$repo_json")"
      echo "Exists: ${FORGEJO_OWNER}/${name_lc} (mirror=${is_mirror}, size=${size_val})"
      echo "FORCE_REMIGRATE=true → deleting then re-importing…"
      delete_repo "$name_lc" || { echo "❌ failed to delete ${name_lc}"; return 0; }
    else
      echo "Already exists: ${FORGEJO_OWNER}/${name_lc} — skipping (set FORCE_REMIGRATE=true to re-import)"
      return 0
    fi
  fi

  local clone_addr="https://github.com/${full_name}.git"
  local mirror=false; [ "$MODE" = "mirror" ] && mirror=true

  # payload (auth_username is important for private HTTPS clone)
  local payload_obj payload_str
  payload_obj="$(jq -n \
    --arg owner "$FORGEJO_OWNER" \
    --arg name  "$name" \
    --arg desc  "$description" \
    --arg addr  "$clone_addr" \
    --arg user  "$GITHUB_USERNAME" \
    --arg pass  "$GITHUB_TOKEN" \
    --arg interval "$MIRROR_INTERVAL" \
    --argjson priv  "$is_private" \
    --argjson mirr  "$mirror" \
    '{
      repo_owner: $owner,
      repo_name: $name,
      description: $desc,
      private: $priv,
      mirror: $mirr,
      mirror_interval: $interval,
      clone_addr: $addr,
      auth_username: $user,
      auth_password: $pass,
      issues: true,
      pull_requests: true,
      wiki: true,
      lfs: true,
      releases: true,
      labels: true,
      milestones: true,
      service: "github"
    }')"
  payload_str="$(jq -c '.' <<<"$payload_obj")"

  echo "Migrating ${full_name} -> ${FORGEJO_OWNER}/${name_lc} (mirror=${mirror})"
  local code body
  read -r code body < <(api_migrate "$payload_str")

  case "$code" in
    200|201)
      echo "✓ Created ${FORGEJO_OWNER}/${name_lc} — syncing…"
      ;;
    409)
      echo "↷ Exists (409): ${name} — (unexpected with FORCE_REMIGRATE=${FORCE_REMIGRATE})"; return 0 ;;
    422)
      echo "⚠️  422 for ${name}: $(jq -r '.message // . | tostring' <<<"$body")"; return 0 ;;
    5*|429)
      echo "⏳ Transient $code for ${name}: $body"; return 0 ;;
    *)
      echo "❗ HTTP $code for ${name}: $body"; return 0 ;;
  esac

  # Post-migrate: wait for content (mirror clone runs in background)
  if wait_for_content "$name"; then
    echo "✓ Content ready: ${FORGEJO_OWNER}/${name_lc}"
  else
    echo "❗ Still empty after ${SYNC_TIMEOUT_SEC}s: ${FORGEJO_OWNER}/${name_lc}"
  fi
}

########################################
# MAIN
########################################
echo "Fetching GitHub repos…"
repos_json="$(gh repo list --limit 1000 --json nameWithOwner,description,isPrivate,isFork,isArchived)"
count="$(jq 'length' <<<"$repos_json")"
echo "Found $count repos"

i=0
while [ $i -lt "$count" ]; do
  full_name="$(jq -r ".[$i].nameWithOwner // \"\"" <<<"$repos_json")"
  description="$(jq -r ".[$i].description // \"\"" <<<"$repos_json")"
  is_private="$(jq -r ".[$i].isPrivate // false" <<<"$repos_json")"
  is_fork="$(jq -r ".[$i].isFork // false" <<<"$repos_json")"
  is_archived="$(jq -r ".[$i].isArchived // false" <<<"$repos_json")"
  migrate_one "$full_name" "$is_private" "$description" "$is_fork" "$is_archived"
  sleep 0.3
  i=$(( i + 1 ))
done

echo "=== Finished ==="
