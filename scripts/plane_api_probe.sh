#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

MODE="dry-run"
ALLOW_MUTATIONS=0
OUTPUT_FILE=""
ONLY_CSV="all"
PAGE_SIZE="${PLANE_PAGE_SIZE:-2}"
LIMIT_VALUE="${PLANE_LIMIT:-2}"
OFFSET_VALUE="${PLANE_OFFSET:-0}"
CURSOR_VALUE="${PLANE_CURSOR:-}"
EXPAND_FIELDS="${PLANE_EXPAND_FIELDS:-state,labels}"
HTTP_TIMEOUT="${PLANE_HTTP_TIMEOUT:-30}"

BASE_URL="${PLANE_BASE_URL:-}"
API_KEY="${PLANE_API_KEY:-}"
WORKSPACE_SLUG="${PLANE_WORKSPACE_SLUG:-}"
PROJECT_ID="${PLANE_PROJECT_ID:-}"
WORK_ITEM_ID="${PLANE_WORK_ITEM_ID:-}"
WORK_ITEM_IDENTIFIER="${PLANE_WORK_ITEM_IDENTIFIER:-}"
TARGET_STATE_ID="${PLANE_TARGET_STATE_ID:-}"
COMMENT_ID="${PLANE_COMMENT_ID:-}"
COMMENT_HTML="${PLANE_COMMENT_HTML:-<p>Codex Plane probe comment</p>}"
COMMENT_UPDATE_HTML="${PLANE_COMMENT_UPDATE_HTML:-<p>Codex Plane probe comment updated</p>}"

RESULTS=()
NOTES=()
TMP_FILES=()
CREATED_COMMENT_ID=""
AUTH_RECORDED=0

LAST_HTTP_STATUS=""
LAST_BODY_FILE=""
LAST_HEADERS_FILE=""
LAST_EFFECTIVE_URL=""

cleanup() {
  if ((${#TMP_FILES[@]})); then
    rm -f "${TMP_FILES[@]}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<EOF2
Usage: $SCRIPT_NAME [options]

Plane API probe for Community Edition compatibility checks.

Modes:
  --dry-run              Print the planned requests only (default)
  --live                 Execute live HTTP requests against Plane
  --mutate               Enable PATCH/POST probes in live mode

Selection:
  --only LIST            Comma-separated subset of probes to run.
                         Supported values:
                         auth,projects,states,work_items,work_item_detail,
                         work_item_identifier,pagination,expand,
                         update_state,create_comment,update_comment

Config flags (override env):
  --base-url URL
  --api-key KEY
  --workspace-slug SLUG
  --project-id UUID
  --work-item-id UUID
  --identifier KEY
  --target-state-id UUID
  --comment-id UUID
  --comment-html HTML
  --comment-update-html HTML
  --page-size N          Value used for per_page and limit probes
  --cursor TOKEN         Cursor used when live response does not expose one
  --expand FIELDS        Defaults to state,labels
  --timeout SECONDS      curl timeout, default 30
  --output FILE          Write the markdown report to FILE
  --help                 Show this message

Environment variables:
  PLANE_BASE_URL
  PLANE_API_KEY
  PLANE_WORKSPACE_SLUG
  PLANE_PROJECT_ID
  PLANE_WORK_ITEM_ID
  PLANE_WORK_ITEM_IDENTIFIER
  PLANE_TARGET_STATE_ID
  PLANE_COMMENT_ID
  PLANE_COMMENT_HTML
  PLANE_COMMENT_UPDATE_HTML
  PLANE_PAGE_SIZE / PLANE_LIMIT / PLANE_OFFSET / PLANE_CURSOR
  PLANE_EXPAND_FIELDS / PLANE_HTTP_TIMEOUT

Examples:
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --live --only auth,projects,states,work_items
  $SCRIPT_NAME --live --mutate --only update_state,create_comment,update_comment
EOF2
}

log_note() {
  NOTES+=("$1")
}

append_result() {
  local status="$1"
  local name="$2"
  local summary="$3"
  RESULTS+=("${status}|${name}|${summary}")
}

shell_quote() {
  printf '%q' "$1"
}

value_or_placeholder() {
  local value="$1"
  local placeholder="$2"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$placeholder"
  fi
}

op_enabled() {
  local needle="$1"
  if [[ "$ONLY_CSV" == "all" ]]; then
    return 0
  fi

  local item
  IFS=',' read -r -a selected <<<"$ONLY_CSV"
  for item in "${selected[@]}"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

ensure_dependency() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    append_result "FAIL" "dependency" "Missing required command: $command_name"
    return 1
  fi
}

require_value() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    append_result "FAIL" "$label" "Missing required value for live probe: $label"
    return 1
  fi
}

base_api_url() {
  printf '%s' "${BASE_URL%/}/api/v1"
}

request_json() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local headers_file body_file status

  headers_file=$(mktemp)
  body_file=$(mktemp)
  TMP_FILES+=("$headers_file" "$body_file")

  local curl_args=(
    -sS
    -X "$method"
    -D "$headers_file"
    -o "$body_file"
    --max-time "$HTTP_TIMEOUT"
    -H "Accept: application/json"
    -H "X-API-Key: $API_KEY"
  )

  if [[ -n "$data" ]]; then
    curl_args+=(
      -H "Content-Type: application/json"
      --data "$data"
    )
  fi

  status=$(curl "${curl_args[@]}" "$url" -w '%{http_code}')

  LAST_HTTP_STATUS="$status"
  LAST_BODY_FILE="$body_file"
  LAST_HEADERS_FILE="$headers_file"
  LAST_EFFECTIVE_URL="$url"
}

first_present() {
  local query="$1"
  jq -r "$query // empty" "$LAST_BODY_FILE" | head -n 1
}

response_count() {
  jq -r '
    if type == "array" then
      length
    elif (.results? | type) == "array" then
      .results | length
    elif (.data? | type) == "array" then
      .data | length
    elif (.items? | type) == "array" then
      .items | length
    else
      "unknown"
    end
  ' "$LAST_BODY_FILE"
}

dry_path() {
  local template="$1"
  template=${template//__WORKSPACE_SLUG__/$(value_or_placeholder "$WORKSPACE_SLUG" '<workspace-slug>')}
  template=${template//__PROJECT_ID__/$(value_or_placeholder "$PROJECT_ID" '<project-id>')}
  template=${template//__WORK_ITEM_ID__/$(value_or_placeholder "$WORK_ITEM_ID" '<work-item-id>')}
  template=${template//__IDENTIFIER__/$(value_or_placeholder "$WORK_ITEM_IDENTIFIER" '<identifier>')}
  template=${template//__STATE_ID__/$(value_or_placeholder "$TARGET_STATE_ID" '<state-id>')}
  template=${template//__COMMENT_ID__/$(value_or_placeholder "$COMMENT_ID" '<comment-id>')}
  printf '%s' "$template"
}

record_dry_run() {
  local name="$1"
  local method="$2"
  local path_template="$3"
  local extras="${4:-}"
  local payload="${5:-}"

  local path
  path=$(dry_path "$path_template")

  local summary="would send ${method} ${path} with X-API-Key header"
  if [[ -n "$extras" ]]; then
    summary+="; ${extras}"
  fi
  if [[ -n "$payload" ]]; then
    summary+="; body=${payload}"
  fi

  append_result "DRY-RUN" "$name" "$summary"
}

record_live_http_result() {
  local name="$1"
  local success_summary="$2"
  local failure_summary="$3"

  if [[ "$LAST_HTTP_STATUS" =~ ^2 ]]; then
    append_result "PASS" "$name" "$success_summary"
  else
    local body_excerpt
    body_excerpt=$(head -c 300 "$LAST_BODY_FILE" | tr '\n' ' ')
    append_result "FAIL" "$name" "${failure_summary}; status=${LAST_HTTP_STATUS}; body=${body_excerpt}"
  fi
}

probe_projects() {
  local path="/workspaces/${WORKSPACE_SLUG}/projects/"

  if [[ "$MODE" == "dry-run" ]]; then
    if ((AUTH_RECORDED == 0)); then
      record_dry_run "auth" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/" "verifies X-API-Key authentication via an authenticated list request"
      AUTH_RECORDED=1
    fi
    record_dry_run "projects" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/"
    return 0
  fi

  require_value "PLANE_BASE_URL" "$BASE_URL" || return 1
  require_value "PLANE_API_KEY" "$API_KEY" || return 1
  require_value "PLANE_WORKSPACE_SLUG" "$WORKSPACE_SLUG" || return 1

  request_json "GET" "$(base_api_url)$path"
  local count
  count=$(response_count)
  record_live_http_result "projects" "GET ${path} returned ${LAST_HTTP_STATUS}; count=${count}" "GET ${path} failed"

  if ((AUTH_RECORDED == 0)); then
    if [[ "$LAST_HTTP_STATUS" =~ ^2 ]]; then
      append_result "PASS" "auth" "Authenticated request accepted using X-API-Key header; status=${LAST_HTTP_STATUS}"
    else
      append_result "FAIL" "auth" "Authenticated request was not accepted using X-API-Key header; status=${LAST_HTTP_STATUS}"
    fi
    AUTH_RECORDED=1
  fi
}

probe_states() {
  local path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/states/"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "states" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/states/"
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1
  request_json "GET" "$(base_api_url)$path"
  local count
  count=$(response_count)
  record_live_http_result "states" "GET ${path} returned ${LAST_HTTP_STATUS}; count=${count}" "GET ${path} failed"
}

probe_work_items() {
  local path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "work_items" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/"
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1
  request_json "GET" "$(base_api_url)$path"
  local count
  count=$(response_count)
  record_live_http_result "work_items" "GET ${path} returned ${LAST_HTTP_STATUS}; count=${count}" "GET ${path} failed"
}

probe_work_item_detail() {
  local path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/${WORK_ITEM_ID}/"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "work_item_detail" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/__WORK_ITEM_ID__/"
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1
  require_value "PLANE_WORK_ITEM_ID" "$WORK_ITEM_ID" || return 1
  request_json "GET" "$(base_api_url)$path"
  local identifier
  identifier=$(first_present '.identifier')
  record_live_http_result "work_item_detail" "GET ${path} returned ${LAST_HTTP_STATUS}; identifier=${identifier:-unknown}" "GET ${path} failed"
}

probe_work_item_identifier() {
  local path="/workspaces/${WORKSPACE_SLUG}/work-items/${WORK_ITEM_IDENTIFIER}/"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "work_item_identifier" "GET" "/workspaces/__WORKSPACE_SLUG__/work-items/__IDENTIFIER__/"
    return 0
  fi

  require_value "PLANE_WORK_ITEM_IDENTIFIER" "$WORK_ITEM_IDENTIFIER" || return 1
  request_json "GET" "$(base_api_url)$path"
  local item_id
  item_id=$(first_present '.id')
  record_live_http_result "work_item_identifier" "GET ${path} returned ${LAST_HTTP_STATUS}; id=${item_id:-unknown}" "GET ${path} failed"
}

probe_expand() {
  local path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/${WORK_ITEM_ID}/?expand=${EXPAND_FIELDS}"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "expand" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/__WORK_ITEM_ID__/?expand=${EXPAND_FIELDS}" "checks expand=${EXPAND_FIELDS}"
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1
  require_value "PLANE_WORK_ITEM_ID" "$WORK_ITEM_ID" || return 1
  request_json "GET" "$(base_api_url)$path"

  if [[ ! "$LAST_HTTP_STATUS" =~ ^2 ]]; then
    record_live_http_result "expand" "expand request unexpectedly succeeded" "expand request failed"
    return 0
  fi

  local state_shape labels_shape
  state_shape=$(jq -r '(.state | type) // "missing"' "$LAST_BODY_FILE" 2>/dev/null || printf 'missing')
  labels_shape=$(jq -r '(.labels | type) // "missing"' "$LAST_BODY_FILE" 2>/dev/null || printf 'missing')
  append_result "PASS" "expand" "expand=${EXPAND_FIELDS} returned ${LAST_HTTP_STATUS}; state=${state_shape}; labels=${labels_shape}"
}

probe_pagination() {
  local base_path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/"
  local limit_url="$(base_api_url)${base_path}?limit=${LIMIT_VALUE}&offset=${OFFSET_VALUE}"
  local cursor_url="$(base_api_url)${base_path}?per_page=${PAGE_SIZE}"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "pagination" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/?limit=${LIMIT_VALUE}&offset=${OFFSET_VALUE}" "official docs baseline"
    record_dry_run "pagination" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/?per_page=${PAGE_SIZE}" "CE divergence probe for per_page/cursor"
    if [[ -n "$CURSOR_VALUE" ]]; then
      record_dry_run "pagination" "GET" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/?per_page=${PAGE_SIZE}&cursor=${CURSOR_VALUE}" "follow-up cursor probe"
    fi
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1

  request_json "GET" "$limit_url"
  if [[ "$LAST_HTTP_STATUS" =~ ^2 ]]; then
    append_result "PASS" "pagination" "limit/offset request returned ${LAST_HTTP_STATUS}; count=$(response_count)"
  else
    append_result "FAIL" "pagination" "limit/offset request failed; status=${LAST_HTTP_STATUS}"
    return 0
  fi

  request_json "GET" "$cursor_url"
  if [[ ! "$LAST_HTTP_STATUS" =~ ^2 ]]; then
    append_result "WARN" "pagination" "per_page request failed or is unsupported; status=${LAST_HTTP_STATUS}"
    return 0
  fi

  local discovered_cursor
  discovered_cursor=$(first_present '.next_cursor // .cursor // .next // .nextCursor')
  if [[ -z "$discovered_cursor" && -n "$CURSOR_VALUE" ]]; then
    discovered_cursor="$CURSOR_VALUE"
  fi

  if [[ -n "$discovered_cursor" ]]; then
    request_json "GET" "$(base_api_url)${base_path}?per_page=${PAGE_SIZE}&cursor=${discovered_cursor}"
    if [[ "$LAST_HTTP_STATUS" =~ ^2 ]]; then
      append_result "PASS" "pagination" "per_page/cursor request returned ${LAST_HTTP_STATUS}; cursor=$(shell_quote "$discovered_cursor")"
    else
      append_result "WARN" "pagination" "cursor follow-up failed; status=${LAST_HTTP_STATUS}; cursor=$(shell_quote "$discovered_cursor")"
    fi
  else
    append_result "WARN" "pagination" "per_page request returned ${LAST_HTTP_STATUS}, but no cursor token was discoverable in the response"
  fi
}

detect_current_state_id() {
  local detail_url="$(base_api_url)/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/${WORK_ITEM_ID}/?expand=state"
  request_json "GET" "$detail_url"
  if [[ ! "$LAST_HTTP_STATUS" =~ ^2 ]]; then
    printf '%s' ""
    return 0
  fi

  first_present '.state.id // .state'
}

probe_update_state() {
  local path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/${WORK_ITEM_ID}/"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "update_state" "PATCH" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/__WORK_ITEM_ID__/" "no-op PATCH when target state is omitted" '{"state":"<uuid>"}'
    return 0
  fi

  if ((ALLOW_MUTATIONS == 0)); then
    append_result "SKIP" "update_state" "Mutation probe skipped; rerun with --mutate to PATCH work item state"
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1
  require_value "PLANE_WORK_ITEM_ID" "$WORK_ITEM_ID" || return 1

  local state_id payload
  state_id="$TARGET_STATE_ID"
  if [[ -z "$state_id" ]]; then
    state_id=$(detect_current_state_id)
  fi

  if [[ -z "$state_id" ]]; then
    append_result "FAIL" "update_state" "Could not determine a target state id; set PLANE_TARGET_STATE_ID or provide a work item whose current state is readable"
    return 0
  fi

  payload=$(jq -cn --arg state "$state_id" '{state: $state}')
  request_json "PATCH" "$(base_api_url)$path" "$payload"
  record_live_http_result "update_state" "PATCH ${path} returned ${LAST_HTTP_STATUS}; state=${state_id}" "PATCH ${path} failed"
}

probe_create_comment() {
  local path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/${WORK_ITEM_ID}/comments/"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "create_comment" "POST" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/__WORK_ITEM_ID__/comments/" "creates a probe comment" '{"comment_html":"..."}'
    return 0
  fi

  if ((ALLOW_MUTATIONS == 0)); then
    append_result "SKIP" "create_comment" "Mutation probe skipped; rerun with --mutate to POST a comment"
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1
  require_value "PLANE_WORK_ITEM_ID" "$WORK_ITEM_ID" || return 1

  local payload
  payload=$(jq -cn --arg html "$COMMENT_HTML" '{comment_html: $html}')
  request_json "POST" "$(base_api_url)$path" "$payload"
  if [[ "$LAST_HTTP_STATUS" =~ ^2 ]]; then
    CREATED_COMMENT_ID=$(first_present '.id')
    append_result "PASS" "create_comment" "POST ${path} returned ${LAST_HTTP_STATUS}; comment_id=${CREATED_COMMENT_ID:-unknown}"
  else
    record_live_http_result "create_comment" "comment create unexpectedly succeeded" "POST ${path} failed"
  fi
}

probe_update_comment() {
  local target_comment_id="$COMMENT_ID"
  if [[ -z "$target_comment_id" ]]; then
    target_comment_id="$CREATED_COMMENT_ID"
  fi

  local path="/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/work-items/${WORK_ITEM_ID}/comments/${target_comment_id}/"

  if [[ "$MODE" == "dry-run" ]]; then
    record_dry_run "update_comment" "PATCH" "/workspaces/__WORKSPACE_SLUG__/projects/__PROJECT_ID__/work-items/__WORK_ITEM_ID__/comments/__COMMENT_ID__/" "updates a probe comment or existing comment id" '{"comment_html":"..."}'
    return 0
  fi

  if ((ALLOW_MUTATIONS == 0)); then
    append_result "SKIP" "update_comment" "Mutation probe skipped; rerun with --mutate to PATCH a comment"
    return 0
  fi

  require_value "PLANE_PROJECT_ID" "$PROJECT_ID" || return 1
  require_value "PLANE_WORK_ITEM_ID" "$WORK_ITEM_ID" || return 1

  if [[ -z "$target_comment_id" ]]; then
    append_result "FAIL" "update_comment" "No comment id available; provide PLANE_COMMENT_ID or run create_comment in the same invocation"
    return 0
  fi

  local payload
  payload=$(jq -cn --arg html "$COMMENT_UPDATE_HTML" '{comment_html: $html}')
  request_json "PATCH" "$(base_api_url)$path" "$payload"
  record_live_http_result "update_comment" "PATCH ${path} returned ${LAST_HTTP_STATUS}" "PATCH ${path} failed"
}

render_report() {
  local overall="PASS"
  local status name summary line

  if ((${#RESULTS[@]} == 0)); then
    overall="DRY-RUN"
  fi

  for line in "${RESULTS[@]}"; do
    IFS='|' read -r status name summary <<<"$line"
    case "$status" in
      FAIL)
        overall="FAIL"
        ;;
      WARN)
        if [[ "$overall" != "FAIL" ]]; then
          overall="WARN"
        fi
        ;;
      SKIP)
        if [[ "$overall" == "PASS" ]]; then
          overall="WARN"
        fi
        ;;
      DRY-RUN)
        if [[ "$overall" == "PASS" ]]; then
          overall="DRY-RUN"
        fi
        ;;
    esac
  done

  cat <<EOF2
# Plane API Probe Report

- Generated at: ${GENERATED_AT}
- Mode: ${MODE}
- Overall: ${overall}
- Mutations: $([[ "$MODE" == "live" && "$ALLOW_MUTATIONS" -eq 1 ]] && printf 'enabled' || printf 'disabled')
- Workspace slug: ${WORKSPACE_SLUG:-<unset>}
- Project id: ${PROJECT_ID:-<unset>}
- Work item id: ${WORK_ITEM_ID:-<unset>}
- Work item identifier: ${WORK_ITEM_IDENTIFIER:-<unset>}

## Results
EOF2

  for line in "${RESULTS[@]}"; do
    IFS='|' read -r status name summary <<<"$line"
    printf -- '- %s `%s`: %s\n' "$status" "$name" "$summary"
  done

  cat <<'EOF2'

## Documentation Baseline

- Checked official Plane API docs on 2026-03-10.
- Projects: https://developers.plane.so/api-reference/project/list-projects
- States: https://developers.plane.so/api-reference/state/list-states
- Work items list: https://developers.plane.so/api-reference/issue/list-issues
- Work item by id: https://developers.plane.so/api-reference/issue/get-issue-detail
- Work item by identifier: https://developers.plane.so/api-reference/issue/get-issue-sequence-id
- Update work item: https://developers.plane.so/api-reference/issue/update-issue-detail
- Create comment: https://developers.plane.so/api-reference/issue-comment/add-issue-comment
- Update comment: https://developers.plane.so/api-reference/issue-comment/update-issue-comment-detail
- Official docs describe list pagination with `limit` and `offset`; this probe also exercises `per_page` and `cursor` to surface Community Edition differences.

## Required Environment

- `PLANE_BASE_URL`, e.g. `https://plane.example.com`
- `PLANE_API_KEY`
- `PLANE_WORKSPACE_SLUG`
- `PLANE_PROJECT_ID` for project-scoped endpoints
- `PLANE_WORK_ITEM_ID` for work item detail and mutation probes
- `PLANE_WORK_ITEM_IDENTIFIER` for identifier lookup
- Optional: `PLANE_TARGET_STATE_ID`, `PLANE_COMMENT_ID`, `PLANE_COMMENT_HTML`, `PLANE_COMMENT_UPDATE_HTML`
EOF2

  if ((${#NOTES[@]})); then
    printf '\n## Notes\n\n'
    local note
    for note in "${NOTES[@]}"; do
      printf -- '- %s\n' "$note"
    done
  fi

  printf '\n'

  if [[ "$overall" == "FAIL" ]]; then
    return 1
  fi

  return 0
}

while (($#)); do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      ;;
    --live)
      MODE="live"
      ;;
    --mutate)
      ALLOW_MUTATIONS=1
      ;;
    --only)
      ONLY_CSV="$2"
      shift
      ;;
    --base-url)
      BASE_URL="$2"
      shift
      ;;
    --api-key)
      API_KEY="$2"
      shift
      ;;
    --workspace-slug)
      WORKSPACE_SLUG="$2"
      shift
      ;;
    --project-id)
      PROJECT_ID="$2"
      shift
      ;;
    --work-item-id)
      WORK_ITEM_ID="$2"
      shift
      ;;
    --identifier)
      WORK_ITEM_IDENTIFIER="$2"
      shift
      ;;
    --target-state-id)
      TARGET_STATE_ID="$2"
      shift
      ;;
    --comment-id)
      COMMENT_ID="$2"
      shift
      ;;
    --comment-html)
      COMMENT_HTML="$2"
      shift
      ;;
    --comment-update-html)
      COMMENT_UPDATE_HTML="$2"
      shift
      ;;
    --page-size)
      PAGE_SIZE="$2"
      LIMIT_VALUE="$2"
      shift
      ;;
    --cursor)
      CURSOR_VALUE="$2"
      shift
      ;;
    --expand)
      EXPAND_FIELDS="$2"
      shift
      ;;
    --timeout)
      HTTP_TIMEOUT="$2"
      shift
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

ensure_dependency curl || true
if [[ "$MODE" == "live" ]]; then
  ensure_dependency jq || true
fi

if [[ "$MODE" == "dry-run" ]]; then
  log_note "Dry-run mode does not require Plane credentials; it validates request coverage and report formatting only."
else
  log_note "Live mode executes real HTTP requests against Plane using X-API-Key authentication."
  if ((ALLOW_MUTATIONS == 0)); then
    log_note "Mutation probes are disabled by default; add --mutate to PATCH/POST work items and comments."
  fi
fi

if op_enabled projects || op_enabled auth; then
  probe_projects || true
fi
if op_enabled states; then
  probe_states || true
fi
if op_enabled work_items; then
  probe_work_items || true
fi
if op_enabled work_item_detail; then
  probe_work_item_detail || true
fi
if op_enabled work_item_identifier; then
  probe_work_item_identifier || true
fi
if op_enabled pagination; then
  probe_pagination || true
fi
if op_enabled expand; then
  probe_expand || true
fi
if op_enabled update_state; then
  probe_update_state || true
fi
if op_enabled create_comment; then
  probe_create_comment || true
fi
if op_enabled update_comment; then
  probe_update_comment || true
fi

set +e
report=$(render_report)
report_status=$?
set -e
printf '%s' "$report"

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%s' "$report" >"$OUTPUT_FILE"
fi

exit "$report_status"
