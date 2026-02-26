#!/usr/bin/env bash
# Run a full A/B test: two Claude Code sessions (with/without CLAUDE.md),
# then analyze the results via MeiliSearch.
#
# Must be run OUTSIDE of a Claude Code session (nested sessions are blocked).
#
# Usage: ./scripts/run-ab-test.sh [repo_path]
#   repo_path  Path to claude-hooks-monitor repo (default: ../claude-hooks-monitor)
#
# Environment:
#   MEILI_URL    MeiliSearch endpoint (default: http://127.0.0.1:7700)
#   MEILI_KEY    MeiliSearch API key (default: none)
#   AB_PROMPT    Override the test prompt (default: architecture explanation prompt)
#   AB_MAX_TURNS Max turns per session (default: 20)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)/claude-hooks-monitor}"
WORKTREE="/tmp/claude-ab-test-no-claudemd"
MEILI_URL="${MEILI_URL:-http://127.0.0.1:7700}"
MEILI_KEY="${MEILI_KEY:-}"
MEILI_INDEX="${MEILI_INDEX:-hook-events}"
MAX_TURNS="${AB_MAX_TURNS:-20}"

PROMPT="${AB_PROMPT:-Explain the architecture of this project and how hook events flow from Claude Code to MeiliSearch. Include the key types, packages, and data transformations involved in the pipeline.}"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓ %s\033[0m\n" "$*"; }
fail() { printf "  \033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

curl_meili() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-s --fail-with-body -X "$method" "$MEILI_URL$path" -H 'Content-Type: application/json')
    if [[ -n "$MEILI_KEY" ]]; then
        args+=(-H "Authorization: Bearer $MEILI_KEY")
    fi
    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi
    curl "${args[@]}"
}

# Get all session IDs currently in MeiliSearch.
get_session_ids() {
    curl_meili POST "/indexes/$MEILI_INDEX/search" \
        '{"facets":["session_id"],"limit":0}' \
        | jq -r '.facetDistribution.session_id // {} | keys[]' | sort
}

# Wait for MeiliSearch to finish indexing (async writes).
wait_for_indexing() {
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local is_indexing
        is_indexing=$(curl -s "$MEILI_URL/indexes/$MEILI_INDEX/stats" | jq '.isIndexing')
        if [[ "$is_indexing" == "false" ]]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "  (warning: MeiliSearch still indexing after ${max_wait}s, proceeding anyway)"
}

# ── Preflight ────────────────────────────────────────────────────────────────

log "Preflight checks"

# Not inside Claude Code?
if [[ -n "${CLAUDECODE:-}" ]]; then
    fail "Cannot run inside a Claude Code session (nested sessions crash). Run this script from a plain terminal."
fi
ok "Not inside Claude Code"

# claude CLI available?
if ! command -v claude &>/dev/null; then
    fail "claude CLI not found in PATH"
fi
ok "claude CLI: $(claude --version 2>/dev/null | head -1)"

# Repo exists?
if [[ ! -d "$REPO/.git" ]]; then
    fail "'$REPO' is not a git repository"
fi
ok "Repo: $REPO"

# MeiliSearch reachable?
if ! curl -sf "$MEILI_URL/health" >/dev/null 2>&1; then
    fail "MeiliSearch not reachable at $MEILI_URL"
fi
ok "MeiliSearch: $MEILI_URL"

# hooks-store reachable?
if curl -sf http://127.0.0.1:9800/health >/dev/null 2>&1; then
    ok "hooks-store: running"
else
    echo "  ⚠ hooks-store not detected on :9800 (events may not be indexed)"
fi

# jq available?
if ! command -v jq &>/dev/null; then
    fail "jq is required but not found"
fi
ok "jq: $(jq --version)"

# ── Snapshot sessions before ─────────────────────────────────────────────────

log "Snapshotting existing sessions"
SESSIONS_BEFORE=$(get_session_ids)
echo "  Found $(echo "$SESSIONS_BEFORE" | grep -c . || echo 0) existing session(s)"

# ── Create worktree ──────────────────────────────────────────────────────────

log "Creating worktree without CLAUDE.md"

if [[ -d "$WORKTREE" ]]; then
    echo "  Worktree already exists, removing..."
    git -C "$REPO" worktree remove "$WORKTREE" --force 2>/dev/null || rm -rf "$WORKTREE"
    if [[ -d "$WORKTREE" ]]; then
        fail "Could not remove existing worktree at $WORKTREE"
    fi
fi

git -C "$REPO" worktree add "$WORKTREE" HEAD --detach
removed=0
while IFS= read -r -d '' f; do
    rm "$f"
    removed=$((removed + 1))
done < <(find "$WORKTREE" -name "CLAUDE.md" -print0)
ok "Worktree at $WORKTREE ($removed CLAUDE.md files removed)"

remaining=$(find "$WORKTREE" -name "CLAUDE.md" | wc -l)
if [[ "$remaining" -ne 0 ]]; then
    fail "$remaining CLAUDE.md files still present!"
fi

# ── Run Session A (with CLAUDE.md) ──────────────────────────────────────────

log "Session A — WITH CLAUDE.md"
echo "  Directory: $REPO"
echo "  Prompt: ${PROMPT:0:80}..."
echo "  Max turns: $MAX_TURNS"
echo ""

SESSION_A_OUTPUT=$(mktemp /tmp/claude-ab-session-a.XXXXXX)
(
    cd "$REPO"
    env -u CLAUDECODE claude -p "$PROMPT" \
        --output-format text \
        --max-turns "$MAX_TURNS" \
        2>&1
) > "$SESSION_A_OUTPUT" || true

ok "Session A complete (output: $SESSION_A_OUTPUT)"

# Give MeiliSearch time to index the events.
echo "  Waiting for MeiliSearch indexing..."
sleep 5
wait_for_indexing

# ── Identify Session A's ID ─────────────────────────────────────────────────

log "Identifying Session A"
SESSIONS_AFTER_A=$(get_session_ids)
SESSION_A_ID=$(comm -13 <(echo "$SESSIONS_BEFORE" | grep -v '^$') <(echo "$SESSIONS_AFTER_A" | grep -v '^$') | head -1)

if [[ -z "$SESSION_A_ID" ]]; then
    echo "  ⚠ Could not detect Session A's ID (hooks may not be configured)."
    echo "  Will try auto-detection after Session B."
else
    ok "Session A ID: $SESSION_A_ID"
fi

# ── Run Session B (without CLAUDE.md) ───────────────────────────────────────

log "Session B — WITHOUT CLAUDE.md"
echo "  Directory: $WORKTREE"
echo "  Prompt: ${PROMPT:0:80}..."
echo "  Max turns: $MAX_TURNS"
echo ""

SESSION_B_OUTPUT=$(mktemp /tmp/claude-ab-session-b.XXXXXX)
(
    cd "$WORKTREE"
    env -u CLAUDECODE claude -p "$PROMPT" \
        --output-format text \
        --max-turns "$MAX_TURNS" \
        2>&1
) > "$SESSION_B_OUTPUT" || true

ok "Session B complete (output: $SESSION_B_OUTPUT)"

echo "  Waiting for MeiliSearch indexing..."
sleep 5
wait_for_indexing

# ── Identify Session B's ID ─────────────────────────────────────────────────

log "Identifying Session B"
SESSIONS_AFTER_B=$(get_session_ids)
SESSION_B_ID=$(comm -13 <(echo "$SESSIONS_AFTER_A" | grep -v '^$') <(echo "$SESSIONS_AFTER_B" | grep -v '^$') | head -1)

if [[ -z "$SESSION_B_ID" ]]; then
    echo "  ⚠ Could not detect Session B's ID."
fi

# ── Run analysis ─────────────────────────────────────────────────────────────

log "Running analysis"

if [[ -n "${SESSION_A_ID:-}" && -n "${SESSION_B_ID:-}" ]]; then
    ok "Session A: $SESSION_A_ID"
    ok "Session B: $SESSION_B_ID"
    echo ""
    MEILI_URL="$MEILI_URL" MEILI_KEY="$MEILI_KEY" MEILI_INDEX="$MEILI_INDEX" \
        "$SCRIPT_DIR/analyze-batch-scans.sh" "$SESSION_A_ID" "$SESSION_B_ID"
else
    echo "  Falling back to auto-detection (two most recent sessions)..."
    echo ""
    MEILI_URL="$MEILI_URL" MEILI_KEY="$MEILI_KEY" MEILI_INDEX="$MEILI_INDEX" \
        "$SCRIPT_DIR/analyze-batch-scans.sh"
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────

log "Cleanup"
git -C "$REPO" worktree remove "$WORKTREE" --force 2>/dev/null && ok "Worktree removed" || echo "  ⚠ Could not remove worktree (remove manually: git -C $REPO worktree remove $WORKTREE)"

echo ""
echo "Session outputs saved to:"
echo "  A (with CLAUDE.md):    $SESSION_A_OUTPUT"
echo "  B (without CLAUDE.md): $SESSION_B_OUTPUT"
