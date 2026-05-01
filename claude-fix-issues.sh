#!/bin/bash
# claude-fix-issues.sh
# Sequentially fix GitHub issues with Claude Code, with rate-limit recovery,
# merge gating, optional triage reordering, Slack notifications, and cron support.

set -uo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

REPO=""
STATE_FILE=".claude-issues-progress.json"
POLL_INTERVAL=60
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"
LABELS="bug,enhancement,feature"
MAX_TURNS=10
TRIAGE_INTERVAL_HOURS=6   # 0 = disabled
ALLOWED_TOOLS="Read,Write,Edit,Bash,Glob,Grep"
BASE_BRANCH=""             # auto-detect if empty
MODE="run"                 # run | triage-only | install-cron | uninstall-cron
CRON_HOURS=6
DRY_RUN=false

# ─── Help ─────────────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
Claude Code Issue Fixer — sequentially fix GitHub issues with merge gating

USAGE
  $0 [OPTIONS]

MODES
  (default)                 Run the main queue processor
  --triage-only             Run a triage session and exit (for cron use)
  --install-cron N          Install cron entry for triage every N hours (1-24)
  --uninstall-cron          Remove the cron entry

OPTIONS
  --repo OWNER/REPO         GitHub repo (default: auto-detect from cwd)
  --state-file PATH         State file path (default: .claude-issues-progress.json)
  --labels LIST             Priority-ordered comma list (default: bug,enhancement,feature)
  --base-branch NAME        Base branch for PRs (default: auto-detect main/master)
  --poll-interval SEC       Seconds between PR merge checks (default: 60)
  --max-turns N             Max Claude turns per issue (default: 10)
  --allowed-tools LIST      Tools Claude can use (default: Read,Write,Edit,Bash,Glob,Grep)
  --triage-interval H       Hours between internal triage (0-24, 0=off, default: 6)
  --slack-webhook URL       Slack webhook URL (or set SLACK_WEBHOOK_URL env)
  --dry-run                 Show what would happen without making changes
  -h, --help                Show this help

ENVIRONMENT
  SLACK_WEBHOOK_URL         Slack incoming webhook URL
  Loads .env from cwd if present.

EXAMPLES
  $0                                  # Run with defaults
  $0 --labels "P0,P1,P2"              # Custom priority order
  $0 --triage-interval 12             # Internal triage every 12h
  $0 --triage-interval 0              # Disable internal triage
  $0 --triage-only                    # One-shot triage (for cron)
  $0 --install-cron 4                 # Cron triage every 4 hours
  $0 --uninstall-cron                 # Remove cron entry

EOF
}

# ─── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)             REPO="$2"; shift 2 ;;
    --state-file)       STATE_FILE="$2"; shift 2 ;;
    --labels)           LABELS="$2"; shift 2 ;;
    --base-branch)      BASE_BRANCH="$2"; shift 2 ;;
    --poll-interval)    POLL_INTERVAL="$2"; shift 2 ;;
    --max-turns)        MAX_TURNS="$2"; shift 2 ;;
    --allowed-tools)    ALLOWED_TOOLS="$2"; shift 2 ;;
    --triage-interval)  TRIAGE_INTERVAL_HOURS="$2"; shift 2 ;;
    --slack-webhook)    SLACK_WEBHOOK="$2"; shift 2 ;;
    --triage-only)      MODE="triage-only"; shift ;;
    --install-cron)     MODE="install-cron"; CRON_HOURS="$2"; shift 2 ;;
    --uninstall-cron)   MODE="uninstall-cron"; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    -h|--help)          show_help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
  esac
done

# Load .env if present
[ -f .env ] && source .env

# Validate
if [[ "$TRIAGE_INTERVAL_HOURS" -lt 0 || "$TRIAGE_INTERVAL_HOURS" -gt 24 ]]; then
  echo "Error: --triage-interval must be 0-24" >&2
  exit 1
fi

# ─── Cron management ──────────────────────────────────────────────────────────

install_cron() {
  if [[ "$CRON_HOURS" -lt 1 || "$CRON_HOURS" -gt 24 ]]; then
    echo "Error: cron interval must be 1-24 hours" >&2
    exit 1
  fi

  local script_path pwd_path repo_arg
  script_path=$(realpath "$0")
  pwd_path=$(pwd)
  repo_arg=""
  [ -n "$REPO" ] && repo_arg="--repo $REPO"

  local cron_line="0 */${CRON_HOURS} * * * cd $pwd_path && $script_path --triage-only $repo_arg >> /tmp/claude-triage.log 2>&1"

  if crontab -l 2>/dev/null | grep -F "$script_path --triage-only" > /dev/null; then
    echo "⚠️  Cron entry already exists. Run --uninstall-cron first to replace."
    exit 1
  fi

  (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
  echo "✅ Installed cron entry — runs every $CRON_HOURS hour(s):"
  echo "   $cron_line"
  echo ""
  echo "ℹ️  Logs: /tmp/claude-triage.log"
  echo "ℹ️  Tip: when running the main script alongside cron, pass --triage-interval 0"
  echo "    to disable internal triage and let cron handle it."
}

uninstall_cron() {
  local script_path
  script_path=$(realpath "$0")

  if ! crontab -l 2>/dev/null | grep -F "$script_path --triage-only" > /dev/null; then
    echo "No cron entry found for this script."
    exit 0
  fi

  crontab -l 2>/dev/null | grep -vF "$script_path --triage-only" | crontab -
  echo "✅ Removed cron entry"
}

# Dispatch cron modes early (don't need repo)
case "$MODE" in
  install-cron)   install_cron; exit 0 ;;
  uninstall-cron) uninstall_cron; exit 0 ;;
esac

# ─── Auto-detect repo & base branch ───────────────────────────────────────────

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Error: Not in a GitHub repo. Use --repo OWNER/REPO" >&2
    exit 1
  }
fi

if [ -z "$BASE_BRANCH" ]; then
  if git show-ref --verify --quiet refs/heads/main; then
    BASE_BRANCH="main"
  elif git show-ref --verify --quiet refs/heads/master; then
    BASE_BRANCH="master"
  else
    BASE_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "main")
  fi
fi

# ─── Slack helpers ────────────────────────────────────────────────────────────

slack() {
  local message="$1"
  [ -z "$SLACK_WEBHOOK" ] && return 0
  $DRY_RUN && { echo "  [dry-run] slack: $message"; return 0; }
  curl -s -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    --data "$(jq -n --arg t "$message" '{text: $t}')" > /dev/null || true
}

# ─── State helpers ────────────────────────────────────────────────────────────

init_state() {
  [ ! -f "$STATE_FILE" ] && echo '{"completed":[],"failed":[],"pending_pr":null,"issue_order":[],"last_reorder":0}' > "$STATE_FILE"
}

state_get()        { jq -r "$1" "$STATE_FILE" 2>/dev/null; }
get_completed()    { state_get '.completed[]'; }
get_pending_pr()   { state_get '.pending_pr'; }
get_last_reorder() { state_get '.last_reorder // 0'; }
get_issue_order()  { state_get '.issue_order // [] | .[]'; }

state_update() {
  local jq_expr="$1"
  jq "$jq_expr" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

mark_completed()   { state_update "(.completed += [$1]) | .pending_pr = null"; }
mark_failed()      { state_update "(.failed += [$1]) | .pending_pr = null"; }
save_pending_pr()  { state_update ".pending_pr = {issue: $1, pr: $2, url: \"$3\"}"; }

# ─── Reset time parser ────────────────────────────────────────────────────────

extract_reset_seconds() {
  local output="$1"
  local reset_time
  reset_time=$(echo "$output" | grep -oiE 'reset at [0-9]{1,2}(:[0-9]{2})?(am|pm)?' | grep -oiE '[0-9]{1,2}(:[0-9]{2})?(am|pm)?' | head -1)
  [ -z "$reset_time" ] && { echo 3600; return; }

  local target now diff
  target=$(date -d "today $reset_time" +%s 2>/dev/null || date -j -f "%I%p" "$reset_time" +%s 2>/dev/null)
  [ -z "$target" ] && { echo 3600; return; }

  now=$(date +%s)
  diff=$(( target - now ))
  [ "$diff" -le 0 ] && diff=$(( diff + 86400 ))
  echo "$diff"
}

# ─── Triage ───────────────────────────────────────────────────────────────────

should_reorder() {
  [ "$TRIAGE_INTERVAL_HOURS" -eq 0 ] && return 1
  local last now elapsed threshold
  last=$(get_last_reorder)
  now=$(date +%s)
  elapsed=$(( now - last ))
  threshold=$(( TRIAGE_INTERVAL_HOURS * 3600 ))
  [ "$elapsed" -ge "$threshold" ]
}

run_triage() {
  echo "🧠 Running triage session for $REPO..."
  slack "🧠 Running issue triage on \`$REPO\` — Claude is reprioritizing open issues."

  local all_issues completed_csv reorder_output ordered_json reasoning
  all_issues=$(gh issue list --repo "$REPO" --state open \
    --json number,title,body,labels --limit 100)

  completed_csv=$(get_completed | tr '\n' ',' | sed 's/,$//')

  if $DRY_RUN; then
    echo "  [dry-run] would call claude -p with $(echo "$all_issues" | jq 'length') issues"
    return 0
  fi

  reorder_output=$(claude -p \
    --output-format json \
    --max-turns 3 \
    "Review GitHub issues for $REPO and produce an optimal work order.

Open issues:
$all_issues

Already completed (skip): $completed_csv

Consider: blocking dependencies, merge conflict risk, quick wins, logical grouping.
Respect this label priority as a strong default: $LABELS

Respond with ONLY this JSON, no other text:
{\"ordered_issues\": [<issue_numbers_in_order>], \"reasoning\": \"<one sentence>\"}" 2>&1)

  ordered_json=$(echo "$reorder_output" | grep -oE '"ordered_issues"[[:space:]]*:[[:space:]]*\[[^]]*\]' | head -1)

  if [ -z "$ordered_json" ]; then
    echo "  ⚠️  Triage didn't return valid ordering — keeping current order"
    slack "⚠️ Triage failed to return valid ordering — keeping current order."
    return 1
  fi

  reasoning=$(echo "$reorder_output" | grep -oE '"reasoning"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/"reasoning"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')
  local ordered_array
  ordered_array=$(echo "$ordered_json" | grep -oE '\[[^]]*\]')

  state_update ".issue_order = $ordered_array | .last_reorder = $(date +%s)"

  echo "  ✅ Reordered: $(echo "$ordered_array" | jq -r 'join(", ")')"
  echo "  📋 $reasoning"
  slack "✅ Issues reprioritized.\n_${reasoning}_"
}

# ─── Issue fetching ───────────────────────────────────────────────────────────

fetch_label_ordered_issues() {
  # Returns TSV: number\ttitle\tbody\tlabel — in priority order, deduped
  local IFS=','
  for label in $LABELS; do
    gh issue list --repo "$REPO" --state open --label "$label" \
      --json number,title,body --limit 100 \
      --jq ".[] | [.number, .title, .body, \"$label\"] | @tsv"
  done | awk -F'\t' '!seen[$1]++'
}

get_next_issue() {
  # Echoes TSV for next issue, or empty if none
  local completed ordered num data
  completed=$(get_completed)
  ordered=$(get_issue_order)

  # Try Claude's ordered list first
  if [ -n "$ordered" ]; then
    while read -r num; do
      [ -z "$num" ] && continue
      if ! echo "$completed" | grep -q "^${num}$"; then
        data=$(gh issue view "$num" --repo "$REPO" \
          --json number,title,body,labels \
          --jq '[.number, .title, .body, (.labels[0].name // "issue")] | @tsv' 2>/dev/null)
        [ -n "$data" ] && { echo "$data"; return; }
      fi
    done <<< "$ordered"
  fi

  # Fallback: label priority
  while IFS= read -r line; do
    num=$(echo "$line" | cut -f1)
    if ! echo "$completed" | grep -q "^${num}$"; then
      echo "$line"
      return
    fi
  done < <(fetch_label_ordered_issues)
}

# ─── Fix one issue ────────────────────────────────────────────────────────────

OUTPUT=""  # global so caller can read after fix_issue

fix_issue() {
  local number=$1 title=$2 body=$3 label=$4
  local branch="fix/issue-$number"

  echo ""
  echo "🔧 [$label] #$number — $title"
  slack "🔧 Starting fix: \`#$number\` — $title (label: $label)"

  if $DRY_RUN; then
    echo "  [dry-run] would run claude -p to fix #$number"
    return 0
  fi

  git checkout "$BASE_BRANCH" --quiet 2>/dev/null
  git pull --quiet
  git branch -D "$branch" 2>/dev/null || true

  OUTPUT=$(claude -p \
    --allowedTools "$ALLOWED_TOOLS" \
    --output-format json \
    --max-turns "$MAX_TURNS" \
    "Fix GitHub issue #$number in this repository.

Label: $label
Title: $title

Description:
$body

Steps:
1. Understand the issue before touching code
2. Make a focused fix — don't refactor unrelated code
3. Run any existing tests (npm test / pytest / go test ./... etc) if present
4. Create branch: $branch
5. Commit: 'fix: $title (closes #$number)'
6. Push: git push origin $branch

Do NOT create a PR — the wrapper script does that." 2>&1)
  local exit_code=$?

  if echo "$OUTPUT" | grep -qiE 'rate.limit|usage.limit|quota|overloaded|429|529|too many requests'; then
    return 2
  fi

  if [ $exit_code -ne 0 ]; then
    echo "  ❌ Claude exited with error"
    slack "❌ Claude failed on \`#$number\` — $title"
    return 1
  fi

  if ! git ls-remote --heads origin "$branch" | grep -q "$branch"; then
    echo "  ❌ Branch was not pushed"
    slack "❌ Branch not pushed for \`#$number\` — $title"
    return 1
  fi

  return 0
}

# ─── PR creation ──────────────────────────────────────────────────────────────

create_pr() {
  local number=$1 title=$2 label=$3
  local branch="fix/issue-$number"

  if $DRY_RUN; then
    echo "  [dry-run] would create PR for $branch"
    echo "999|https://example.com/dry-run"
    return 0
  fi

  local pr_url pr_number
  pr_url=$(gh pr create \
    --repo "$REPO" \
    --head "$branch" \
    --base "$BASE_BRANCH" \
    --title "fix: $title" \
    --body "Fixes #$number

---
Label: \`$label\`

*Automated fix by Claude Code. Review the Railway preview before merging.*" 2>&1)

  if [ $? -ne 0 ]; then
    echo "  ❌ PR creation failed: $pr_url"
    slack "❌ PR creation failed for \`#$number\`: $pr_url"
    return 1
  fi

  pr_number=$(gh pr view "$branch" --repo "$REPO" --json number -q .number 2>/dev/null)
  echo "${pr_number}|${pr_url}"
}

# ─── Wait for merge ───────────────────────────────────────────────────────────

wait_for_merge() {
  local pr_number=$1 pr_url=$2 issue_number=$3 title=$4

  echo "  ⏸  PR #$pr_number open — waiting for merge..."
  echo "     $pr_url"
  slack "⏸ PR ready for review: <$pr_url|#$pr_number — $title>\nRailway is deploying a preview. Merge when ready and the next issue starts."

  if $DRY_RUN; then
    echo "  [dry-run] would poll PR #$pr_number until merged"
    mark_completed "$issue_number"
    return 0
  fi

  while true; do
    local state
    state=$(gh pr view "$pr_number" --repo "$REPO" --json state -q .state 2>/dev/null)

    if [ "$state" = "MERGED" ]; then
      echo "  ✅ Merged."
      slack "✅ PR #$pr_number merged — \`#$issue_number\`. Starting next."
      mark_completed "$issue_number"
      return 0
    elif [ "$state" = "CLOSED" ]; then
      echo "  ⚠️  PR closed without merging."
      slack "⚠️ PR #$pr_number closed without merging — \`#$issue_number\`."
      mark_failed "$issue_number"
      return 1
    fi

    sleep "$POLL_INTERVAL"
  done
}

# ─── Main loops ───────────────────────────────────────────────────────────────

run_main() {
  init_state

  echo "🚀 Issue fixer — $REPO"
  echo "   Base branch: $BASE_BRANCH"
  echo "   Labels (priority): $LABELS"
  echo "   Triage: $([ "$TRIAGE_INTERVAL_HOURS" -eq 0 ] && echo 'disabled' || echo "every ${TRIAGE_INTERVAL_HOURS}h")"
  $DRY_RUN && echo "   ⚠️  DRY RUN MODE"
  echo ""

  slack "🚀 Issue fixer started on \`$REPO\` (labels: $LABELS)"

  # Resume in-flight PR
  local pending p_issue p_pr p_url
  pending=$(get_pending_pr)
  if [ "$pending" != "null" ] && [ -n "$pending" ]; then
    p_issue=$(echo "$pending" | jq -r '.issue')
    p_pr=$(echo "$pending" | jq -r '.pr')
    p_url=$(echo "$pending" | jq -r '.url')
    echo "🔄 Resuming PR #$p_pr for issue #$p_issue"
    slack "🔄 Resuming PR #$p_pr for issue \`#$p_issue\`"
    wait_for_merge "$p_pr" "$p_url" "$p_issue" "(resumed)"
  fi

  while true; do
    # Internal triage
    should_reorder && run_triage

    # Get next issue
    local next_issue number title body label
    next_issue=$(get_next_issue)

    if [ -z "$next_issue" ]; then
      echo "✅ No more open issues to process."
      slack "🎉 All done. Completed: $(jq '.completed | length' "$STATE_FILE") | Failed: $(jq '.failed | length' "$STATE_FILE")"
      break
    fi

    IFS=$'\t' read -r number title body label <<< "$next_issue"

    fix_issue "$number" "$title" "$body" "$label"
    local result=$?

    if [ $result -eq 2 ]; then
      local wait_secs wait_min
      wait_secs=$(extract_reset_seconds "$OUTPUT")
      wait_min=$(( wait_secs / 60 ))
      echo "⏳ Rate limited. Resuming in ~${wait_min} min."
      slack "⏳ Usage limit hit. Resuming in ~${wait_min} minutes."
      sleep "$wait_secs"
      continue
    elif [ $result -eq 1 ]; then
      mark_failed "$number"
      continue
    fi

    local pr_result pr_number pr_url
    pr_result=$(create_pr "$number" "$title" "$label")
    if [ $? -ne 0 ]; then
      mark_failed "$number"
      continue
    fi

    pr_number=$(echo "$pr_result" | cut -d'|' -f1)
    pr_url=$(echo "$pr_result" | cut -d'|' -f2)

    save_pending_pr "$number" "$pr_number" "$pr_url"
    wait_for_merge "$pr_number" "$pr_url" "$number" "$title"

    sleep 5
  done
}

run_triage_only() {
  init_state
  echo "🧠 Triage-only mode — $REPO"
  run_triage
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

case "$MODE" in
  run)          run_main ;;
  triage-only)  run_triage_only ;;
  *)            echo "Unknown mode: $MODE" >&2; exit 1 ;;
esac
