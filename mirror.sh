#!/usr/bin/env bash
#
# mirror.sh — Mirrors every repository of a GitHub account (and optional orgs)
#             into GitLab, keeping branches and tags in sync.
#
# Runs portably on any system (Linux, macOS, containers) via cron, systemd, or manually.
# Does NOT need a browser or automation frameworks: uses only the GitHub and
# GitLab REST APIs via curl, plus git and jq.
#
# Usage:
#   mirror.sh                 # mirror every repository
#   mirror.sh --repo user/r   # mirror a single repository
#   mirror.sh --list          # list the repositories that would be mirrored
#   mirror.sh --dry-run       # show actions without cloning or pushing
#   mirror.sh --help
#
# Configuration:
#   Loaded from .env in project root by default, or $ENV_FILE / $MIRROR_CONFIG,
#   or directly from environment variables.
#
set -uo pipefail

# Prevent git from hanging on interactive prompts.
export GIT_TERMINAL_PROMPT=0

VERSION="1.1.0"
PROG="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"

# Resolve configuration file (.env by default, or via ENV_FILE / MIRROR_CONFIG)
CONFIG_FILE="${ENV_FILE:-${MIRROR_CONFIG:-}}"
if [ -z "$CONFIG_FILE" ]; then
  if [ -f "$BASE_DIR/.env" ]; then
    CONFIG_FILE="$BASE_DIR/.env"
  elif [ -f "$PWD/.env" ]; then
    CONFIG_FILE="$PWD/.env"
  fi
fi

NOTIFY="$SCRIPT_DIR/notify.sh"

START_TS=$SECONDS
TOTAL=0
declare -a UPDATED=()
declare -a REPAIRED=()
declare -a SKIPPED=()
declare -a FAILED=()
declare -a FILTERED=()
KEPT=""
LOG_FILE=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
$PROG $VERSION — GitHub -> GitLab mirror

Usage:
  $PROG                    Mirror every repository of the configured account.
  $PROG --repo SLUG        Mirror only "owner/repo".
  $PROG --list             List repositories without mirroring anything.
  $PROG --dry-run          Preview actions without cloning, creating projects, or pushing.
  $PROG --skip-archived    Skip archived repositories (default).
  $PROG --include-archived Include archived repositories.
  $PROG --help             Show this help.

Configuration:
  Defaults to .env file in project root ($BASE_DIR/.env),
  or path specified via ENV_FILE / MIRROR_CONFIG,
  or standard ambient environment variables.
EOF
}

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s  %s\n' "$ts" "$*"
  if [ -n "$LOG_FILE" ]; then
    printf '%s  %s\n' "$ts" "$*" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
MODE="all"
ONLY_REPO=""
DRY_RUN="false"
CLI_DRY_RUN=""
CLI_SKIP_ARCHIVED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) ONLY_REPO="${2:-}"; MODE="one"; shift 2 ;;
    --repo=*) ONLY_REPO="${1#*=}"; MODE="one"; shift ;;
    --list) MODE="list"; shift ;;
    -n|--dry-run) DRY_RUN="true"; CLI_DRY_RUN="true"; shift ;;
    --skip-archived) CLI_SKIP_ARCHIVED="true"; shift ;;
    --include-archived) CLI_SKIP_ARCHIVED="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Configuration loading & defaults
# ---------------------------------------------------------------------------
if [ -n "$CONFIG_FILE" ]; then
  [ -f "$CONFIG_FILE" ] || die "Cannot find configuration file: $CONFIG_FILE"
  # shellcheck disable=SC1090
  set -a
  source "$CONFIG_FILE"
  set +a
fi

GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_ORGS="${GITHUB_ORGS:-}"
GITHUB_INCLUDE_FORKS="${GITHUB_INCLUDE_FORKS:-false}"
GITHUB_SKIP_ARCHIVED="${GITHUB_SKIP_ARCHIVED:-}"
if [ -z "$GITHUB_SKIP_ARCHIVED" ] && [ -n "${GITHUB_INCLUDE_ARCHIVED:-}" ]; then
  [ "$GITHUB_INCLUDE_ARCHIVED" = "true" ] && GITHUB_SKIP_ARCHIVED="false" || GITHUB_SKIP_ARCHIVED="true"
fi
GITHUB_SKIP_ARCHIVED="${GITHUB_SKIP_ARCHIVED:-true}"
if [ -n "$CLI_SKIP_ARCHIVED" ]; then
  GITHUB_SKIP_ARCHIVED="$CLI_SKIP_ARCHIVED"
fi
[ "$GITHUB_SKIP_ARCHIVED" = "true" ] && GITHUB_INCLUDE_ARCHIVED="false" || GITHUB_INCLUDE_ARCHIVED="true"
GITHUB_EXCLUDE="${GITHUB_EXCLUDE:-}"

GITLAB_USER="${GITLAB_USER:-}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_HOST="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_GROUP="${GITLAB_GROUP:-}"
GITLAB_VISIBILITY="${GITLAB_VISIBILITY:-private}"
GITLAB_AUTO_CREATE="${GITLAB_AUTO_CREATE:-true}"
GITLAB_SSH_HOST="${GITLAB_SSH_HOST:-gitlab.com}"

MIRROR_DIR="${MIRROR_DIR:-$BASE_DIR/data/repos}"
LOG_DIR="${LOG_DIR:-}"
GIT_PROTOCOL="${GIT_PROTOCOL:-https}"
PUSH_ALWAYS="${PUSH_ALWAYS:-true}"
DRY_RUN="${DRY_RUN:-false}"

EMAIL_NOTIFY="${EMAIL_NOTIFY:-false}"
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_FROM="${EMAIL_FROM:-$(hostname 2>/dev/null || echo 'localhost')}"
EMAIL_ON_SUCCESS="${EMAIL_ON_SUCCESS:-false}"
MSMTP_CONFIG="${MSMTP_CONFIG:-}"
MSMTP_ACCOUNT="${MSMTP_ACCOUNT:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

# Resolve relative paths relative to BASE_DIR
case "$MIRROR_DIR" in
  /*) ;;
  *) MIRROR_DIR="$BASE_DIR/$MIRROR_DIR" ;;
esac
if [ -n "$LOG_DIR" ]; then
  case "$LOG_DIR" in
    /*) ;;
    *) LOG_DIR="$BASE_DIR/$LOG_DIR" ;;
  esac
fi

GITLAB_HOST="${GITLAB_HOST%/}"
GITHUB_API_URL="${GITHUB_API_URL%/}"
GITLAB_HOSTNAME="${GITLAB_HOST#*://}"
GITLAB_HOSTNAME="${GITLAB_HOSTNAME%%/*}"

# CLI dry-run override
[ "$CLI_DRY_RUN" = "true" ] && DRY_RUN="true"

# Validate tools & tokens
command -v git >/dev/null 2>&1 || die "git is not installed (please install git)"
command -v curl >/dev/null 2>&1 || die "curl is not installed (please install curl)"
command -v jq >/dev/null 2>&1 || die "jq is not installed (please install jq)"

[ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN is required (set in .env or environment)"
[ -n "$GITLAB_TOKEN" ] || die "GITLAB_TOKEN is required (set in .env or environment)"

# ---------------------------------------------------------------------------
# API Helpers
# ---------------------------------------------------------------------------
gh_get() {
  curl -fsS \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

gitlab_api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -fsS -X "$method" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$data" "${GITLAB_HOST}/api/v4${path}"
  else
    curl -fsS -X "$method" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${GITLAB_HOST}/api/v4${path}"
  fi
}

# Auto-detect GitHub user if not set
if [ -z "$GITHUB_USER" ]; then
  GITHUB_USER="$(gh_get "${GITHUB_API_URL}/user" 2>/dev/null | jq -r '.login // empty')"
  [ -n "$GITHUB_USER" ] || die "GITHUB_USER could not be autodetected (verify GITHUB_TOKEN or set GITHUB_USER)"
fi

# Auto-detect GitLab user if not set
if [ -z "$GITLAB_USER" ]; then
  GITLAB_USER="$(gitlab_api GET "/user" 2>/dev/null | jq -r '.username // empty')"
  if [ -z "$GITLAB_USER" ] && [ -z "$GITLAB_GROUP" ]; then
    die "GITLAB_USER could not be autodetected (verify GITLAB_TOKEN or set GITLAB_USER / GITLAB_GROUP)"
  fi
fi

GITLAB_NAMESPACE="${GITLAB_GROUP:-$GITLAB_USER}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE#/}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE%/}"
[ -n "$GITLAB_NAMESPACE" ] || die "GitLab target namespace could not be determined (set GITLAB_USER or GITLAB_GROUP)"

# ---------------------------------------------------------------------------
# Directories and log file
# ---------------------------------------------------------------------------
mkdir -p "$MIRROR_DIR" 2>/dev/null || die "Cannot create mirror directory: $MIRROR_DIR"
chmod 700 "$MIRROR_DIR" 2>/dev/null || true

if [ -n "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR" 2>/dev/null || die "Cannot create log directory: $LOG_DIR"
  LOG_FILE="$LOG_DIR/mirror-$(date +%Y%m%d).log"
  ln -sfn "$LOG_FILE" "$LOG_DIR/latest.log" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Report + notification (always runs on exit)
# ---------------------------------------------------------------------------
build_filter() {
  local forks archived
  [ "$GITHUB_INCLUDE_FORKS" = "true" ] && forks=true || forks=false
  [ "$GITHUB_INCLUDE_ARCHIVED" = "true" ] && archived=true || archived=false
  printf '.[] | select((.fork==false) or (%s)) | select((.archived==false) or (%s)) | .full_name' \
    "$forks" "$archived"
}

build_report() {
  local status="$1" code="$2"
  {
    echo "Status:     $status (exit=$code)"
    echo "Date:       $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Host:       $(hostname 2>/dev/null || echo 'localhost')"
    echo "Mode:       $([ "$DRY_RUN" = "true" ] && echo 'DRY-RUN (nothing was modified)' || echo 'normal')"
    echo "Source:     GitHub ${GITHUB_USER}${GITHUB_ORGS:+ (orgs: $GITHUB_ORGS)}"
    echo "Target:     GitLab ${GITLAB_NAMESPACE:-?} @ ${GITLAB_HOST}"
    echo "Duration:   $((SECONDS - START_TS)) s"
    echo
    echo "Repositories processed : $TOTAL"
    echo "Updated                : ${#UPDATED[@]}"
    echo "Repaired               : ${#REPAIRED[@]}"
    echo "Unchanged              : ${#SKIPPED[@]}"
    echo "Failed                 : ${#FAILED[@]}"
    echo "Excluded by filter     : ${#FILTERED[@]}"
    if [ "${#FAILED[@]}" -gt 0 ]; then
      echo
      echo "Repositories with errors:"
      printf '  - %s\n' "${FAILED[@]}"
    fi
    if [ "${#UPDATED[@]}" -gt 0 ]; then
      echo
      echo "Updated repositories:"
      printf '  - %s\n' "${UPDATED[@]}"
    fi
    echo
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
      echo "Last lines of the log ($LOG_FILE):"
      echo "------------------------------------------------------------"
      tail -n 40 "$LOG_FILE"
    else
      echo "Log file: disabled (streaming directly to stdout / journal)"
    fi
  }
}

send_webhook() {
  local subject="$1" body="$2"
  [ -n "$WEBHOOK_URL" ] || return 0
  local text="*${subject}*
\`\`\`
${body}
\`\`\`"
  curl -fsS -m 20 -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$text" '{text:$t}')" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

finish() {
  local code=$?
  if [ "$EMAIL_NOTIFY" != "true" ] && [ -z "$WEBHOOK_URL" ]; then
    return "$code"
  fi

  local failed_n=${#FAILED[@]}
  if [ "$failed_n" -eq 0 ] && [ "$code" -eq 0 ] && [ "$EMAIL_ON_SUCCESS" != "true" ]; then
    return "$code"
  fi

  local host_label; host_label="$(hostname 2>/dev/null || echo 'localhost')"
  local status subject
  if [ "$failed_n" -gt 0 ] || [ "$code" -ne 0 ]; then
    status="FAILED"
    subject="[GitHub Mirror] ✗ ${failed_n} repo(s) with errors on ${host_label}"
  else
    status="OK"
    subject="[GitHub Mirror] ✓ OK on ${host_label} (${#UPDATED[@]} updated)"
  fi
  [ "$DRY_RUN" = "true" ] && subject="[GitHub Mirror] (dry-run) ${subject#\[GitHub Mirror\] }"

  local body
  body="$(build_report "$status" "$code")"

  if [ "$EMAIL_NOTIFY" = "true" ] && [ -n "$EMAIL_TO" ]; then
    EMAIL_SUBJECT="$subject" \
    EMAIL_TO="$EMAIL_TO" \
    EMAIL_FROM="$EMAIL_FROM" \
    MSMTP_CONFIG="$MSMTP_CONFIG" \
    MSMTP_ACCOUNT="$MSMTP_ACCOUNT" \
      "$NOTIFY" <<<"$body" || true
  fi

  send_webhook "$subject" "$body" || true
  return "$code"
}
trap finish EXIT

# ---------------------------------------------------------------------------
# GitHub Repository Discovery
# ---------------------------------------------------------------------------
list_user_repos() {
  local filter="$1" page=1 json n
  while :; do
    json="$(gh_get "${GITHUB_API_URL}/user/repos?affiliation=owner&per_page=100&page=${page}&sort=full_name")" || return 1
    n="$(printf '%s' "$json" | jq 'length')"
    printf '%s' "$json" | jq -r "$filter"
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
}

list_org_repos() {
  local org="$1" filter="$2" page=1 json n
  while :; do
    json="$(gh_get "${GITHUB_API_URL}/orgs/${org}/repos?type=all&per_page=100&page=${page}&sort=full_name")" || return 1
    n="$(printf '%s' "$json" | jq 'length')"
    printf '%s' "$json" | jq -r "$filter"
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
}

collect_repos() {
  local filter; filter="$(build_filter)"
  list_user_repos "$filter" || return 1
  local org
  for org in $GITHUB_ORGS; do
    list_org_repos "$org" "$filter" || return 1
  done
}

# Match whitespace-separated patterns in GITHUB_EXCLUDE
is_excluded() {
  local slug="$1" name="${1##*/}" pattern
  [ -n "$GITHUB_EXCLUDE" ] || return 1
  for pattern in $GITHUB_EXCLUDE; do
    # shellcheck disable=SC2254
    case "$slug" in $pattern) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$name" in $pattern) return 0 ;; esac
  done
  return 1
}

filter_repos() {
  local input="$1" slug
  KEPT=""
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if is_excluded "$slug"; then
      FILTERED+=("$slug")
    else
      KEPT+="$slug"$'\n'
    fi
  done <<<"$input"
  KEPT="${KEPT%$'\n'}"
}

# ---------------------------------------------------------------------------
# GitLab Helpers
# ---------------------------------------------------------------------------
gitlab_group_id() {
  gitlab_api GET "/groups/$(urlencode "$GITLAB_GROUP")" 2>/dev/null | jq -r '.id'
}

ensure_gitlab_project() {
  local name="$1" project_path namespace_id payload
  [ "$GITLAB_AUTO_CREATE" = "true" ] || return 0

  project_path="${GITLAB_NAMESPACE}/${name}"
  if gitlab_api GET "/projects/$(urlencode "$project_path")" >/dev/null 2>&1; then
    return 0
  fi

  log "  + creating GitLab project: ${project_path}"
  namespace_id=""
  if [ -n "$GITLAB_GROUP" ]; then
    namespace_id="$(gitlab_group_id)"
    if [ -z "$namespace_id" ] || [ "$namespace_id" = "null" ]; then
      log "  ERROR: cannot find GitLab group '${GITLAB_GROUP}'"
      return 1
    fi
  fi

  payload="$(jq -n \
    --arg n "$name" --arg p "$name" --arg v "$GITLAB_VISIBILITY" --arg ns "$namespace_id" \
    '{name:$n, path:$p, visibility:$v}
     + (if $ns != "" then {namespace_id: ($ns|tonumber)} else {} end)')"

  gitlab_api POST "/projects" "$payload" >/dev/null
}

# ---------------------------------------------------------------------------
# Mirroring a single repository
# ---------------------------------------------------------------------------
refs_snapshot() {
  git -C "$1" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags 2>/dev/null | sort
}

ls_refs() {
  git ls-remote --heads --tags "$1" 2>/dev/null \
    | grep -v '\^{}' | awk '{print $1" "$2}' | sort || true
}

repo_urls() {
  # $1 = owner, $2 = name. Sets GH_URL and GL_URL.
  if [ "$GIT_PROTOCOL" = "ssh" ]; then
    GH_URL="git@github.com:${1}/${2}.git"
    GL_URL="git@${GITLAB_SSH_HOST}:${GITLAB_NAMESPACE}/${2}.git"
  else
    GH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${1}/${2}.git"
    GL_URL="https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOSTNAME}/${GITLAB_NAMESPACE}/${2}.git"
  fi
}

mirror_repo_dry() {
  local slug="$1" name="$2" project_path
  project_path="${GITLAB_NAMESPACE}/${name}"

  local gh_refs
  gh_refs="$(ls_refs "$GH_URL")"
  if [ -z "$gh_refs" ]; then
    log "  ✗ $slug — cannot read refs from GitHub (verify token / network)"
    FAILED+=("$slug (dry-run: github)")
    return 1
  fi
  local n_gh
  n_gh="$(printf '%s\n' "$gh_refs" | grep -c . || true)"

  local project_exists=0
  if gitlab_api GET "/projects/$(urlencode "$project_path")" >/dev/null 2>&1; then
    project_exists=1
  else
    log "  [dry-run] would create GitLab project: ${project_path}"
  fi

  local gl_refs
  gl_refs="$(ls_refs "$GL_URL")"

  if [ "$project_exists" = "0" ] || [ "$gh_refs" != "$gl_refs" ]; then
    log "  ↑ $slug — would update (${n_gh} refs on GitHub, [dry-run])"
    UPDATED+=("$slug")
  else
    log "  · $slug — unchanged (${n_gh} refs, [dry-run])"
    SKIPPED+=("$slug")
  fi
  return 0
}

run_git_cmd() {
  local dir="$1"; shift
  local err_output
  if [ -n "$LOG_FILE" ]; then
    git -C "$dir" "$@" >>"$LOG_FILE" 2>&1
  else
    if ! err_output="$(git -C "$dir" "$@" 2>&1)"; then
      [ -n "$err_output" ] && log "    $err_output"
      return 1
    fi
  fi
}

mirror_repo() {
  local slug="$1" owner name dir first=0
  owner="${slug%%/*}"
  name="${slug##*/}"

  if [ -z "$owner" ] || [ -z "$name" ] || [ "$owner" = "$slug" ]; then
    log "  Invalid repository slug: '$slug' (expected 'owner/repo')"
    FAILED+=("$slug (invalid slug)")
    return 1
  fi

  dir="$MIRROR_DIR/$owner/$name.git"
  repo_urls "$owner" "$name"

  if [ "$DRY_RUN" = "true" ]; then
    mirror_repo_dry "$slug" "$name"
    return $?
  fi

  if ! ensure_gitlab_project "$name"; then
    log "  ✗ $slug — could not prepare GitLab destination project"
    FAILED+=("$slug (GitLab project)")
    return 1
  fi

  if [ ! -d "$dir" ]; then
    log "  • cloning $slug ..."
    mkdir -p "$(dirname "$dir")" || { FAILED+=("$slug (mkdir)"); return 1; }
    git init --bare -q "$dir" || { FAILED+=("$slug (git init)"); return 1; }
    git -C "$dir" remote add origin "$GH_URL" 2>/dev/null || git -C "$dir" remote set-url origin "$GH_URL"
    git -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
    git -C "$dir" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
    git -C "$dir" remote add gitlab "$GL_URL" 2>/dev/null || git -C "$dir" remote set-url gitlab "$GL_URL"
    first=1
  else
    git -C "$dir" remote set-url origin "$GH_URL" 2>/dev/null || git -C "$dir" remote add origin "$GH_URL"
    git -C "$dir" remote set-url gitlab "$GL_URL" 2>/dev/null || git -C "$dir" remote add gitlab "$GL_URL"
  fi

  local before after remote_refs changed=0
  before="$(refs_snapshot "$dir")"

  if ! run_git_cmd "$dir" fetch --prune --quiet --tags origin; then
    log "  ✗ $slug — 'git fetch' from GitHub failed"
    FAILED+=("$slug (fetch)")
    return 1
  fi

  after="$(refs_snapshot "$dir")"
  [ "$before" != "$after" ] && changed=1

  remote_refs="$(git -C "$dir" ls-remote --heads --tags gitlab 2>/dev/null \
    | grep -v '\^{}' | awk '{print $1" "$2}' | sort || true)"

  if [ "$first" = 1 ] || [ "$changed" = 1 ] || [ "$remote_refs" != "$after" ] || [ "$PUSH_ALWAYS" = "true" ]; then
    if ! run_git_cmd "$dir" push --mirror --quiet gitlab; then
      log "  ✗ $slug — 'git push' to GitLab failed"
      FAILED+=("$slug (push)")
      return 1
    fi
    if [ "$first" = 1 ]; then
      log "  + $slug — mirror created"
      UPDATED+=("$slug")
    elif [ "$changed" = 1 ]; then
      log "  ↑ $slug — updated"
      UPDATED+=("$slug")
    elif [ "$remote_refs" != "$after" ]; then
      log "  = $slug — repaired (remote was out of sync)"
      REPAIRED+=("$slug")
    else
      log "  · $slug — unchanged"
      SKIPPED+=("$slug")
    fi
  else
    log "  · $slug — unchanged"
    SKIPPED+=("$slug")
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "===== GitHub -> GitLab mirror v$VERSION $([ "$DRY_RUN" = "true" ] && echo '(DRY-RUN: nothing is modified)') ====="
  log "GitHub: ${GITHUB_USER}${GITHUB_ORGS:+ (+ orgs: $GITHUB_ORGS)}  ->  GitLab: ${GITLAB_NAMESPACE}@${GITLAB_HOSTNAME}"

  local repos
  if [ "$MODE" = "one" ]; then
    repos="$ONLY_REPO"
  else
    if ! repos="$(collect_repos)"; then
      die "Could not fetch repository list from GitHub (check token and permissions)"
    fi
    filter_repos "$repos"
    repos="$KEPT"
  fi

  if [ "$MODE" = "list" ]; then
    printf '%s\n' "$repos"
    return 0
  fi

  if [ "${#FILTERED[@]}" -gt 0 ]; then
    log "Excluded ${#FILTERED[@]} repo(s) via GITHUB_EXCLUDE: ${FILTERED[*]}"
  fi

  if [ -z "$repos" ]; then
    log "No repositories to mirror."
  fi

  local repo tag=""
  [ "$DRY_RUN" = "true" ] && tag="[dry-run] "
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    TOTAL=$((TOTAL + 1))
    log "→ $repo"
    mirror_repo "$repo" || true
  done <<<"$repos"

  log "===== ${tag}Summary: $TOTAL repos | ${#UPDATED[@]} updated | ${#REPAIRED[@]} repaired | ${#SKIPPED[@]} unchanged | ${#FAILED[@]} failed | ${#FILTERED[@]} excluded | $((SECONDS - START_TS))s ====="
  return 0
}

main "$@"
