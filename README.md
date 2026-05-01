# Claude AutoFix

Automatically fix GitHub issues using Claude Code, with merge gating, intelligent triage, rate-limit recovery, and Slack notifications.

## What it does

Claude AutoFix is a self-hosted issue processor that:

1. **Fetches open issues** from your GitHub repo (prioritized by labels)
2. **Calls Claude Code** to fix each issue, with full access to your repository
3. **Creates PRs** for each fix
4. **Waits for merge** before moving to the next issue (merge gating)
5. **Handles rate limits** gracefully by resuming after reset
6. **Runs AI triage** periodically to reorder issues by impact
7. **Sends Slack notifications** at each step (optional)
8. **Supports cron scheduling** for periodic triage

Think of it as a 24/7 junior developer that fixes bugs and features, one PR at a time.

## Installation

```bash
git clone https://github.com/coffeewithayman/claude-autofix.git
cd claude-autofix
```

## Requirements

- **Claude Code CLI** (https://claude.com/claude-code)
- **GitHub CLI** (`gh`) with authenticated access
- **Bash 4+**
- **jq** for JSON parsing
- **curl** for Slack webhooks (optional)

## Quick start

```bash
./claude-fix-issues.sh --repo owner/repo
```

This will:
- Auto-detect the default branch (`main` or `master`)
- Fetch issues labeled `bug`, `enhancement`, or `feature` (in that order)
- Fix issues one at a time
- Create PRs and wait for merge
- Run triage every 6 hours to reorder remaining issues

## Usage

```
Claude Code Issue Fixer — sequentially fix GitHub issues with merge gating

USAGE
  ./claude-fix-issues.sh [OPTIONS]

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
```

## Examples

### Run with default settings
```bash
./claude-fix-issues.sh
```

### Use custom label priority (P0 > P1 > P2)
```bash
./claude-fix-issues.sh --labels "P0,P1,P2"
```

### Disable internal triage, use cron instead
```bash
./claude-fix-issues.sh --triage-interval 0
./claude-fix-issues.sh --install-cron 4  # Triage every 4 hours via cron
```

### Test run (dry-run mode)
```bash
./claude-fix-issues.sh --dry-run
```

### One-shot triage (for cron)
```bash
./claude-fix-issues.sh --triage-only
```

## Configuration

### Environment variables

```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
./claude-fix-issues.sh
```

Or pass inline:
```bash
./claude-fix-issues.sh --slack-webhook "https://hooks.slack.com/services/..."
```

### .env file

Create `.env` in the same directory:
```bash
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
```

## State tracking

Progress is saved to `.claude-issues-progress.json`:

```json
{
  "completed": [123, 456],
  "failed": [789],
  "pending_pr": {
    "issue": 234,
    "pr": 567,
    "url": "https://github.com/..."
  },
  "issue_order": [111, 222, 333],
  "last_reorder": 1704067200
}
```

- **completed**: Issues fixed and merged
- **failed**: Issues Claude couldn't fix
- **pending_pr**: In-flight PR waiting for merge (auto-resumes on restart)
- **issue_order**: AI-optimized order from triage
- **last_reorder**: Unix timestamp of last triage run

You can edit this file manually to re-queue issues or reset state.

## How it works

### Merge gating

The script creates a PR for each issue and **waits for it to be merged** before fixing the next one. This ensures:
- PRs are reviewed and approved before moving on
- No merge conflicts pile up
- Clear audit trail of what was fixed
- Easy rollback if a fix breaks something

If you close a PR without merging, the issue is marked as failed and skipped.

### Triage

Every 6 hours (configurable), Claude reviews all open issues and reorders them by:
- Blocking dependencies (fixes that unblock other issues)
- Merge conflict risk
- Quick wins
- Logical grouping
- Your label priority as a strong default

This keeps the queue optimized without manual intervention.

### Rate limiting

If Claude hits an API rate limit:
1. The script detects the error
2. Extracts the reset time from the error message
3. Sleeps until reset
4. Automatically resumes the current issue

### Resume on restart

If the script crashes or is stopped while waiting for a PR to merge:
- State is saved to `.claude-issues-progress.json`
- Restarting the script resumes the pending PR
- No work is lost or duplicated

## Slack notifications

Optional. Sends updates at:
- Script start/end
- Each issue start
- PR creation and merge
- Triage runs
- Rate limit hits
- Failures

Set `SLACK_WEBHOOK_URL` to enable.

## Cron scheduling

Install periodic triage (runs separately from main script):

```bash
./claude-fix-issues.sh --install-cron 4
```

This:
- Adds a cron entry to run triage every 4 hours
- Logs to `/tmp/claude-triage.log`
- Respects the state file and completed/failed lists

**Tip:** Run the main script with `--triage-interval 0` to let cron handle triage and avoid conflicts.

## Tool restrictions

By default, Claude can only use:
- `Read` — read files
- `Write` — write files
- `Edit` — edit files
- `Bash` — run commands
- `Glob` — find files
- `Grep` — search files

Expand with `--allowed-tools`:
```bash
./claude-fix-issues.sh --allowed-tools "Read,Write,Edit,Bash,Glob,Grep,Agent"
```

## Known limitations

- **No parallel fixes**: Processes one issue at a time (by design, for merge gating)
- **Manual PR review required**: All PRs need human approval to merge
- **Label-based only**: Fetches issues by label, not milestones or other criteria
- **No issue comments**: Doesn't reply to issues; all updates go to Slack

## Troubleshooting

### Script is stuck waiting for a PR

Check PR status:
```bash
gh pr view <pr-number> --repo owner/repo
```

If the PR is closed/merged, manually update `.claude-issues-progress.json`:
```bash
# Mark issue as completed
jq '.completed += [123] | .pending_pr = null' .claude-issues-progress.json > .tmp && mv .tmp .claude-issues-progress.json

# Then restart the script
./claude-fix-issues.sh
```

### Claude isn't running the fix

Check `claude --version` and ensure:
1. Claude Code CLI is installed
2. You're authenticated to GitHub
3. The repo path is correct
4. `--allowed-tools` includes the tools Claude needs

### Triage isn't reordering issues

Verify `--triage-interval` > 0 and Claude has enough context (max 100 issues fetched).

### Slack messages aren't sending

Check:
1. Webhook URL is valid
2. Webhook has message permissions
3. Test: `curl -X POST "$SLACK_WEBHOOK_URL" -H 'Content-type: application/json' --data '{"text":"test"}'`

## Contributing

Feedback, bug reports, and PRs welcome at https://github.com/coffeewithayman/claude-autofix/issues

## License

MIT
