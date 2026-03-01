#!/usr/bin/env bash
# Run a carry-forward A/B experiment:
#   Session A: carry-forward ENABLED  → compaction → measure post-compact re-reads
#   Session B: carry-forward DISABLED → compaction → measure post-compact re-reads
#
# Both sessions keep CLAUDE.md (hold constant). The only variable is carry-forward.
#
# Must be run OUTSIDE of a Claude Code session (nested sessions are blocked).
#
# Usage: ./scripts/run-carryforward-experiment.sh [repo_path]
#   repo_path  Path to claude-hooks-monitor repo (default: ../claude-hooks-monitor)
#
# Environment:
#   MEILI_URL        MeiliSearch endpoint (default: http://127.0.0.1:7700)
#   MEILI_KEY        MeiliSearch API key (default: none)
#   AB_PROMPT        Override the test prompt
#   AB_MAX_TURNS     Max turns per session (default: 50)
#   COMPACT_WINDOW   Seconds after compaction to count re-reads (default: 300)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)/claude-hooks-monitor}"
MEILI_URL="${MEILI_URL:-http://127.0.0.1:7700}"
MEILI_KEY="${MEILI_KEY:-}"
MEILI_INDEX="${MEILI_INDEX:-hook-events}"
MAX_TURNS="${AB_MAX_TURNS:-50}"
COMPACT_WINDOW="${COMPACT_WINDOW:-300}"
MONITOR_BIN="${MONITOR_BIN:-$(cd "$SCRIPT_DIR/../.." && pwd)/claude-hooks-monitor/bin/monitor}"
CONFIG_FILE="${HOME}/.config/claude-hooks-monitor/hook_monitor.conf"

# A prompt designed to fill the context window through multiple read-only analysis
# passes over the codebase. Each step forces re-reading files and producing verbose
# output, maximizing context consumption to trigger compaction.
# The prompt is generic — works on any codebase, not tied to Go or specific packages.
PROMPT="${AB_PROMPT:-You are performing a comprehensive read-only codebase audit. Do NOT modify any files. You MUST complete every step below IN ORDER. After each step, write a DETAILED report (at least 500 words) before moving to the next. Do NOT skip or combine steps.

Step 1 — INVENTORY: Find and list every source file in the project. Read each file and record: path, line count, primary responsibility, and all public symbols (functions, types, constants).

Step 2 — DEPENDENCY MAP: Re-read all source files. For each file, list every import/use/require and trace where each dependency is defined. Draw the full internal dependency graph as ASCII art.

Step 3 — DATA FLOW ANALYSIS: Re-read all files that handle I/O (HTTP, files, stdin, databases). Trace every piece of external data from entry point through transformation to storage or output. Identify trust boundaries.

Step 4 — ERROR HANDLING AUDIT: Re-read every source file. Catalog every error path: what errors can occur, how they are propagated, whether they are logged, and whether callers handle them. List any swallowed or silently ignored errors.

Step 5 — CONCURRENCY REVIEW: Re-read all files that use threads, goroutines, async, mutexes, channels, or shared state. Identify all concurrent access patterns. Analyze lock ordering, potential deadlocks, and race conditions. If no concurrency exists, document why and whether it should.

Step 6 — API SURFACE ANALYSIS: Re-read all public interfaces (HTTP handlers, CLI entry points, exported functions). Document every input parameter, its validation, accepted ranges, and what happens with malformed input. Include wire formats (JSON schemas, CLI flags).

Step 7 — TEST COVERAGE GAPS: Read all test files. For each test, explain what behavior it verifies. Then re-read the corresponding source files and identify untested code paths, edge cases, and boundary conditions. Rank gaps by severity.

Step 8 — CONFIGURATION AUDIT: Re-read all config loading code and entry points. Map every configuration source (env vars, files, flags, defaults). Document precedence order, what happens when config is missing, and whether defaults are safe.

Step 9 — PERFORMANCE REVIEW: Re-read files with loops, allocations, I/O, or data structures. Identify potential performance bottlenecks: O(n^2) patterns, unbounded allocations, blocking calls in hot paths, missing caching opportunities.

Step 10 — ARCHITECTURE ASSESSMENT: Re-read the 5 most important files in the project. Write a 1000+ word architectural review: evaluate separation of concerns, coupling between modules, extensibility, and technical debt. Compare against best practices for the language/framework used.

CRITICAL: You must re-read actual source files at every step. Do not rely on memory from previous steps. Write thorough, verbose analysis. This is a read-only audit — do not create, edit, or write any files.}"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓ %s\033[0m\n" "$*"; }
fail() { printf "  \033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
warn() { printf "  \033[33m⚠ %s\033[0m\n" "$*"; }

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

get_session_ids() {
    curl_meili POST "/indexes/$MEILI_INDEX/search" \
        '{"facets":["session_id"],"limit":0}' \
        | jq -r '.facetDistribution.session_id // {} | keys[]' | sort
}

wait_for_indexing() {
    local max_wait=30 waited=0
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

stop_existing_monitor() {
    # Kill any already-running monitor (single-instance lock prevents coexistence).
    local existing_pid
    existing_pid=$(pgrep -x monitor 2>/dev/null | head -1 || true)
    if [[ -z "$existing_pid" ]]; then
        existing_pid=$(pgrep -f "bin/monitor" 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$existing_pid" ]]; then
        kill "$existing_pid" 2>/dev/null
        sleep 1
        if kill -0 "$existing_pid" 2>/dev/null; then
            kill -9 "$existing_pid" 2>/dev/null || true
            sleep 1
        fi
        ok "Stopped existing monitor (PID $existing_pid)"
    fi
}

start_monitor() {
    log "Starting monitor"
    stop_existing_monitor
    "$MONITOR_BIN" &
    MONITOR_PID=$!
    sleep 2
    if ! kill -0 "$MONITOR_PID" 2>/dev/null; then
        fail "Monitor failed to start"
    fi
    ok "Monitor running (PID $MONITOR_PID)"
}

stop_monitor() {
    if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null
        wait "$MONITOR_PID" 2>/dev/null || true
        ok "Monitor stopped (PID $MONITOR_PID)"
        MONITOR_PID=""
    fi
}

# Toggle carry-forward in config file.
# Usage: set_carryforward "yes" | "no"
set_carryforward() {
    local enabled="$1"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        fail "Config file not found: $CONFIG_FILE"
    fi

    # Remove existing [carry-forward] section if present.
    local tmp
    tmp=$(mktemp)
    awk '
        /^\[carry-forward\]/ { skip=1; next }
        /^\[/ { skip=0 }
        !skip { print }
    ' "$CONFIG_FILE" > "$tmp"

    # Append new [carry-forward] section.
    cat >> "$tmp" <<EOF

[carry-forward]
enabled = $enabled
EOF

    mv "$tmp" "$CONFIG_FILE"
    ok "carry-forward set to: $enabled"
}

cleanup() {
    stop_monitor
    # Restore carry-forward to enabled (default).
    if [[ -f "$CONFIG_FILE" ]]; then
        set_carryforward "yes" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Preflight ────────────────────────────────────────────────────────────────

log "Preflight checks"

if [[ -n "${CLAUDECODE:-}" ]]; then
    fail "Cannot run inside a Claude Code session (nested sessions crash). Run from a plain terminal."
fi
ok "Not inside Claude Code"

if ! command -v claude &>/dev/null; then
    fail "claude CLI not found in PATH"
fi
ok "claude CLI: $(claude --version 2>/dev/null | head -1)"

if [[ ! -f "$MONITOR_BIN" ]]; then
    fail "Monitor binary not found: $MONITOR_BIN (run 'make build' first)"
fi
ok "Monitor binary: $MONITOR_BIN"

if [[ ! -d "$REPO/.git" ]]; then
    fail "'$REPO' is not a git repository"
fi
ok "Repo: $REPO"

if ! curl -sf "$MEILI_URL/health" >/dev/null 2>&1; then
    fail "MeiliSearch not reachable at $MEILI_URL"
fi
ok "MeiliSearch: $MEILI_URL"

if curl -sf http://127.0.0.1:9800/health >/dev/null 2>&1; then
    ok "hooks-store: running"
else
    warn "hooks-store not detected on :9800 (events may not be indexed)"
fi

if ! command -v jq &>/dev/null; then
    fail "jq is required but not found"
fi
ok "jq: $(jq --version)"

if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Monitor config not found: $CONFIG_FILE"
fi
ok "Config: $CONFIG_FILE"

# ── Experiment info ──────────────────────────────────────────────────────────

log "Experiment configuration"
echo "  Variable:          carry-forward (enabled vs disabled)"
echo "  Control:           CLAUDE.md present in both sessions"
echo "  Max turns:         $MAX_TURNS"
echo "  Compact window:    ${COMPACT_WINDOW}s"
echo "  Prompt:            ${PROMPT:0:100}..."
echo ""

# ── Snapshot sessions before ─────────────────────────────────────────────────

log "Snapshotting existing sessions"
SESSIONS_BEFORE=$(get_session_ids)
echo "  Found $(echo "$SESSIONS_BEFORE" | grep -c . || echo 0) existing session(s)"

# ── Session A: carry-forward ENABLED ─────────────────────────────────────────

log "Configuring carry-forward: ENABLED"
set_carryforward "yes"

start_monitor

log "Session A — carry-forward ENABLED (compaction experiment)"
echo "  Directory: $REPO"
echo "  Max turns: $MAX_TURNS"
echo ""

SESSION_A_OUTPUT=$(mktemp /tmp/claude-cf-session-a.XXXXXX)
(
    cd "$REPO"
    env -u CLAUDECODE claude -p "$PROMPT" \
        --output-format text \
        --max-turns "$MAX_TURNS" \
        2>&1
) > "$SESSION_A_OUTPUT" || true

ok "Session A complete (output: $SESSION_A_OUTPUT)"

echo "  Waiting for MeiliSearch indexing..."
sleep 5
wait_for_indexing

# ── Identify Session A ───────────────────────────────────────────────────────

log "Identifying Session A"
SESSIONS_AFTER_A=$(get_session_ids)
SESSION_A_ID=$(comm -13 <(echo "$SESSIONS_BEFORE" | grep -v '^$') <(echo "$SESSIONS_AFTER_A" | grep -v '^$') | head -1)

if [[ -z "$SESSION_A_ID" ]]; then
    warn "Could not detect Session A's ID (hooks may not be configured)."
else
    ok "Session A ID: $SESSION_A_ID"
    compact_a=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
        "$(printf '{"filter":"session_id = '\''%s'\'' AND hook_type = '\''PreCompact'\''","limit":0}' "$SESSION_A_ID")" \
        | jq '.estimatedTotalHits // 0')
    echo "  Compaction events in A: $compact_a"
fi

# ── Session B: carry-forward DISABLED ────────────────────────────────────────

stop_monitor

log "Configuring carry-forward: DISABLED"
set_carryforward "no"

start_monitor

log "Session B — carry-forward DISABLED (compaction experiment)"
echo "  Directory: $REPO"
echo "  Max turns: $MAX_TURNS"
echo ""

SESSION_B_OUTPUT=$(mktemp /tmp/claude-cf-session-b.XXXXXX)
(
    cd "$REPO"
    env -u CLAUDECODE claude -p "$PROMPT" \
        --output-format text \
        --max-turns "$MAX_TURNS" \
        2>&1
) > "$SESSION_B_OUTPUT" || true

ok "Session B complete (output: $SESSION_B_OUTPUT)"

echo "  Waiting for MeiliSearch indexing..."
sleep 5
wait_for_indexing

# ── Identify Session B ───────────────────────────────────────────────────────

log "Identifying Session B"
SESSIONS_AFTER_B=$(get_session_ids)
SESSION_B_ID=$(comm -13 <(echo "$SESSIONS_AFTER_A" | grep -v '^$') <(echo "$SESSIONS_AFTER_B" | grep -v '^$') | head -1)

if [[ -z "$SESSION_B_ID" ]]; then
    warn "Could not detect Session B's ID."
fi

stop_monitor

# ── Analysis ─────────────────────────────────────────────────────────────────

log "Running compaction analysis"
echo "  A = carry-forward ENABLED  (both sessions have CLAUDE.md)"
echo "  B = carry-forward DISABLED (both sessions have CLAUDE.md)"
echo "  Only variable: carry-forward toggle"
echo ""

if [[ -n "${SESSION_A_ID:-}" && -n "${SESSION_B_ID:-}" ]]; then
    ok "Session A (carry-forward ON):  $SESSION_A_ID"
    ok "Session B (carry-forward OFF): $SESSION_B_ID"
    echo ""
    LABEL_A="carry-forward ON" LABEL_B="carry-forward OFF" \
        MEILI_URL="$MEILI_URL" MEILI_KEY="$MEILI_KEY" MEILI_INDEX="$MEILI_INDEX" \
        COMPACT_WINDOW="$COMPACT_WINDOW" \
        "$SCRIPT_DIR/analyze-compaction.sh" "$SESSION_A_ID" "$SESSION_B_ID"
else
    echo "  Falling back to auto-detection (two most recent sessions)..."
    echo ""
    LABEL_A="carry-forward ON" LABEL_B="carry-forward OFF" \
        MEILI_URL="$MEILI_URL" MEILI_KEY="$MEILI_KEY" MEILI_INDEX="$MEILI_INDEX" \
        COMPACT_WINDOW="$COMPACT_WINDOW" \
        "$SCRIPT_DIR/analyze-compaction.sh"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

log "Experiment complete"
echo ""
echo "  Session A (carry-forward ON):  $SESSION_A_OUTPUT"
echo "  Session B (carry-forward OFF): $SESSION_B_OUTPUT"
echo ""
echo "  If neither session triggered compaction, try:"
echo "    AB_MAX_TURNS=80 ./scripts/run-carryforward-experiment.sh"
