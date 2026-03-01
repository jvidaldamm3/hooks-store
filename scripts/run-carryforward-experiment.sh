#!/usr/bin/env bash
# Run a carry-forward A/B experiment:
#   Session A: carry-forward ENABLED  → compaction → measure post-compact re-reads
#   Session B: carry-forward DISABLED → compaction → measure post-compact re-reads
#
# Both sessions keep CLAUDE.md (hold constant). The only variable is carry-forward.
# Each session runs in its own git worktree so code changes don't affect the original.
#
# Must be run OUTSIDE of a Claude Code session (nested sessions are blocked).
#
# Usage: ./scripts/run-carryforward-experiment.sh [repo_path]
#   repo_path  Path to the target repo (default: ../claude-hooks-monitor)
#
# Environment:
#   MEILI_URL        MeiliSearch endpoint (default: http://127.0.0.1:7700)
#   MEILI_KEY        MeiliSearch API key (default: none)
#   AB_PROMPT        Override the test prompt
#   AB_MAX_TURNS     Max turns per session (default: 80)
#   COMPACT_WINDOW   Seconds after compaction to count re-reads (default: 300)
#   WORKTREE_MODE    Set to "no" to run directly in REPO (default: yes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)/claude-hooks-monitor}"
MEILI_URL="${MEILI_URL:-http://127.0.0.1:7700}"
MEILI_KEY="${MEILI_KEY:-}"
MEILI_INDEX="${MEILI_INDEX:-hook-events}"
MAX_TURNS="${AB_MAX_TURNS:-80}"
COMPACT_WINDOW="${COMPACT_WINDOW:-300}"
MONITOR_BIN="${MONITOR_BIN:-$(cd "$SCRIPT_DIR/../.." && pwd)/claude-hooks-monitor/bin/monitor}"
CONFIG_FILE="${HOME}/.config/claude-hooks-monitor/hook_monitor.conf"
WORKTREE_MODE="${WORKTREE_MODE:-yes}"

# Worktree paths (under /tmp to avoid polluting the repo).
WORKTREE_A="/tmp/claude-cf-worktree-a"
WORKTREE_B="/tmp/claude-cf-worktree-b"

# An intensive multi-phase prompt that combines reading, writing, reviewing, and
# rewriting. Each phase forces deep engagement with the codebase, naturally filling
# the context window through real work rather than artificial re-read instructions.
# Defined via heredoc to avoid bash parsing issues with special characters.
DEFAULT_PROMPT=$(cat <<'PROMPT_EOF'
You are performing a comprehensive codebase overhaul. Complete ALL phases below IN ORDER. Each phase builds on the previous. Be extremely thorough — read every file before changing it, verify changes compile or pass checks, and write detailed explanations.

═══════════════════════════════════════════════════════════
PHASE 1 — DEEP CODE REVIEW (read every source file)
═══════════════════════════════════════════════════════════

Read every source file in the project. For each file, write a detailed review covering:
- Purpose and responsibility (is it well-scoped or doing too much?)
- Code quality: naming conventions, function length, cognitive complexity
- Error handling: are errors propagated correctly? Any swallowed errors?
- Edge cases: what inputs or states could cause unexpected behavior?
- Thread safety: any shared mutable state without proper synchronization?
- API design: are public interfaces clean, minimal, and well-documented?

Rate each file A/B/C/D for quality. List every issue found with file path and line reference.

═══════════════════════════════════════════════════════════
PHASE 2 — BUG HUNTING AND FIXING
═══════════════════════════════════════════════════════════

Re-read all source files with a security and correctness mindset. Hunt for:
- Off-by-one errors, boundary conditions, integer overflow potential
- Resource leaks (unclosed files, connections, goroutines, channels)
- Race conditions and TOCTOU vulnerabilities
- Nil/null pointer dereferences, uninitialized variables
- Input validation gaps (injection, path traversal, overflow)
- Logic errors in conditionals, loops, and state machines
- Dead code paths that indicate missing functionality
- Panics or unrecoverable errors that should be handled gracefully

For each bug found: explain the bug, show the problematic code, explain the fix, then APPLY the fix. Re-read the file after fixing to verify correctness.

═══════════════════════════════════════════════════════════
PHASE 3 — CODE SIMPLIFICATION
═══════════════════════════════════════════════════════════

Re-read every file you reviewed in Phase 1. For each file, identify opportunities to:
- Replace verbose patterns with idiomatic constructs
- Extract repeated logic into well-named helper functions
- Reduce nesting depth (guard clauses, early returns)
- Simplify complex conditionals into clearer expressions
- Remove unnecessary abstractions or over-engineering
- Consolidate duplicated code across files
- Replace manual loops with standard library functions where clearer

Apply each simplification. Show the before/after for significant changes. Re-read modified files to ensure nothing broke.

═══════════════════════════════════════════════════════════
PHASE 4 — DOCUMENTATION AND COMMENTS
═══════════════════════════════════════════════════════════

Re-read all source files (including your modifications from Phases 2-3). Add or improve comments:
- Every exported/public function, type, and constant needs a doc comment explaining WHAT it does, WHY it exists, and any non-obvious behavior
- Complex algorithms need step-by-step inline comments
- Non-obvious design decisions need "why" comments (not "what" comments)
- Remove any misleading, outdated, or redundant comments
- Add package-level documentation explaining the package's role in the system
- Document all assumptions, invariants, and constraints
- Add examples in doc comments for non-trivial public APIs

Keep comments concise and high-signal. A good comment explains WHY, not WHAT.

═══════════════════════════════════════════════════════════
PHASE 5 — ROBUSTNESS HARDENING
═══════════════════════════════════════════════════════════

Re-read all source files again. Harden the codebase:
- Add input validation at every public API boundary
- Add defensive nil/null checks where callers might pass bad data
- Ensure all error returns include enough context for debugging
- Add timeouts to all blocking operations (network, file I/O, channels)
- Ensure graceful degradation when dependencies are unavailable
- Add or improve logging at key decision points (with structured fields)
- Verify all cleanup happens even in error paths (defer, finally, try-with-resources)
- Check that configuration has sensible defaults and validates ranges

Apply each hardening change. Verify the build still passes after each batch of changes.

═══════════════════════════════════════════════════════════
PHASE 6 — CROSS-CUTTING CONSISTENCY REVIEW
═══════════════════════════════════════════════════════════

Re-read EVERY file in the project one final time. Check for cross-cutting consistency:
- Naming conventions: are similar concepts named the same way across packages?
- Error patterns: is the error handling style consistent across the codebase?
- Logging: same format, same levels, same structured fields everywhere?
- Configuration: consistent precedence (flags > env > file > defaults) across all settings?
- Testing patterns: same assertion style, same test structure, same mocking approach?
- Import organization: same grouping and ordering everywhere?

Fix any inconsistencies found. Write a final summary report with:
- Total issues found and fixed (by category)
- Files modified (with brief description of changes)
- Remaining technical debt or known limitations
- Architecture quality assessment (1-10 with justification)

CRITICAL INSTRUCTIONS:
- You MUST read actual source files before every modification — never work from memory.
- Each phase requires re-reading files, even if you read them in a previous phase.
- Apply all fixes and improvements directly — do not just list recommendations.
- After each phase, briefly verify the project still builds or tests pass.
- Write detailed explanations for every change to justify your decisions.
- If you find issues during a later phase that relate to an earlier phase, go back and fix them.
PROMPT_EOF
)
PROMPT="${AB_PROMPT:-$DEFAULT_PROMPT}"

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

# Verify a session's cwd matches the expected path.
# Returns 0 if match, 1 if not (or if session has no events).
verify_session_cwd() {
    local session_id="$1" expected_cwd="$2"
    local cwd
    cwd=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
        "$(printf '{"filter":"session_id = '\''%s'\''","sort":["timestamp_unix:asc"],"limit":1}' "$session_id")" \
        | jq -r '.hits[0].data.cwd // ""')
    # Normalize: resolve symlinks and strip trailing slash.
    local norm_cwd norm_expected
    norm_cwd=$(echo "$cwd" | sed 's|/$||')
    norm_expected=$(cd "$expected_cwd" 2>/dev/null && pwd -P | sed 's|/$||')
    [[ "$norm_cwd" == "$norm_expected" ]]
}

# From a list of new session IDs, find the one whose cwd matches a given path.
find_matching_session() {
    local new_sessions="$1" target_dir="$2"
    while IFS= read -r sid; do
        [[ -z "$sid" ]] && continue
        if verify_session_cwd "$sid" "$target_dir"; then
            echo "$sid"
            return 0
        fi
    done <<< "$new_sessions"
    return 1
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

# ── Worktree management ─────────────────────────────────────────────────────

create_worktree() {
    local wt_path="$1" label="$2"
    if [[ -d "$wt_path" ]]; then
        echo "  Removing stale worktree at $wt_path..."
        git -C "$REPO" worktree remove "$wt_path" --force 2>/dev/null || rm -rf "$wt_path"
    fi
    git -C "$REPO" worktree add "$wt_path" HEAD --detach
    ok "Worktree $label: $wt_path"
}

remove_worktree() {
    local wt_path="$1"
    if [[ -d "$wt_path" ]]; then
        git -C "$REPO" worktree remove "$wt_path" --force 2>/dev/null || rm -rf "$wt_path"
    fi
}

# Verify hook-client is available. It's a global binary (in PATH or ~/.local/bin),
# not a per-repo artifact — no need to copy anything into worktrees.
check_hook_client() {
    if command -v hook-client &>/dev/null; then
        ok "hook-client: $(command -v hook-client)"
    elif [[ -f "$HOME/.local/bin/hook-client" ]]; then
        ok "hook-client: $HOME/.local/bin/hook-client"
    else
        warn "hook-client not found in PATH — sessions won't emit events"
    fi
}

# ── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    stop_monitor
    # Restore carry-forward to enabled (default).
    if [[ -f "$CONFIG_FILE" ]]; then
        set_carryforward "yes" 2>/dev/null || true
    fi
    # Remove worktrees.
    if [[ "$WORKTREE_MODE" == "yes" ]]; then
        remove_worktree "$WORKTREE_A" 2>/dev/null || true
        remove_worktree "$WORKTREE_B" 2>/dev/null || true
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

check_hook_client

if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Monitor config not found: $CONFIG_FILE"
fi
ok "Config: $CONFIG_FILE"

# ── Experiment info ──────────────────────────────────────────────────────────

log "Experiment configuration"
echo "  Variable:          carry-forward (enabled vs disabled)"
echo "  Control:           CLAUDE.md present in both sessions"
echo "  Worktree mode:     $WORKTREE_MODE"
echo "  Max turns:         $MAX_TURNS"
echo "  Compact window:    ${COMPACT_WINDOW}s"
echo "  Prompt:            ${PROMPT:0:100}..."
echo ""

# ── Create worktrees ─────────────────────────────────────────────────────────

if [[ "$WORKTREE_MODE" == "yes" ]]; then
    log "Creating worktrees (original repo stays untouched)"
    create_worktree "$WORKTREE_A" "A (carry-forward ON)"
    create_worktree "$WORKTREE_B" "B (carry-forward OFF)"
    SESSION_A_DIR="$WORKTREE_A"
    SESSION_B_DIR="$WORKTREE_B"
else
    SESSION_A_DIR="$REPO"
    SESSION_B_DIR="$REPO"
fi

# ── Snapshot sessions before ─────────────────────────────────────────────────

log "Snapshotting existing sessions"
SESSIONS_BEFORE=$(get_session_ids)
echo "  Found $(echo "$SESSIONS_BEFORE" | grep -c . || echo 0) existing session(s)"

# ── Session A: carry-forward ENABLED ─────────────────────────────────────────

log "Configuring carry-forward: ENABLED"
set_carryforward "yes"

start_monitor

log "Session A — carry-forward ENABLED"
echo "  Directory: $SESSION_A_DIR"
echo "  Max turns: $MAX_TURNS"
echo ""

SESSION_A_OUTPUT=$(mktemp /tmp/claude-cf-session-a.XXXXXX)
(
    cd "$SESSION_A_DIR"
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
NEW_A=$(comm -13 <(echo "$SESSIONS_BEFORE" | grep -v '^$') <(echo "$SESSIONS_AFTER_A" | grep -v '^$'))
SESSION_A_ID=$(find_matching_session "$NEW_A" "$SESSION_A_DIR" || true)

if [[ -z "$SESSION_A_ID" ]]; then
    warn "Could not detect Session A's ID (no new session matched cwd=$SESSION_A_DIR)."
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

log "Session B — carry-forward DISABLED"
echo "  Directory: $SESSION_B_DIR"
echo "  Max turns: $MAX_TURNS"
echo ""

SESSION_B_OUTPUT=$(mktemp /tmp/claude-cf-session-b.XXXXXX)
(
    cd "$SESSION_B_DIR"
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
NEW_B=$(comm -13 <(echo "$SESSIONS_AFTER_A" | grep -v '^$') <(echo "$SESSIONS_AFTER_B" | grep -v '^$'))
SESSION_B_ID=$(find_matching_session "$NEW_B" "$SESSION_B_DIR" || true)

if [[ -z "$SESSION_B_ID" ]]; then
    warn "Could not detect Session B's ID (no new session matched cwd=$SESSION_B_DIR)."
fi

stop_monitor

# ── Analysis ─────────────────────────────────────────────────────────────────

log "Running compaction analysis"
echo "  A = carry-forward ENABLED  (both sessions have CLAUDE.md)"
echo "  B = carry-forward DISABLED (both sessions have CLAUDE.md)"
echo "  Only variable: carry-forward toggle"
if [[ "$WORKTREE_MODE" == "yes" ]]; then
    echo "  Isolation: git worktrees (original repo untouched)"
fi
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
if [[ "$WORKTREE_MODE" == "yes" ]]; then
    echo ""
    echo "  Worktrees cleaned up automatically."
    echo "  Original repo at $REPO was not modified."
fi
echo ""
echo "  If neither session triggered compaction, try:"
echo "    AB_MAX_TURNS=100 ./scripts/run-carryforward-experiment.sh $REPO"
