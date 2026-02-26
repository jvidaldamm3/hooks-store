#!/usr/bin/env bash
# Run a complete CLAUDE.md impact experiment: two Claude Code sessions under
# identical conditions except for the presence of CLAUDE.md files, then gather
# all event data and produce an unbiased analysis report.
#
# Must be run OUTSIDE of a Claude Code session (nested sessions are blocked).
#
# Usage: ./scripts/run-full-experiment.sh [repo_path]
#   repo_path  Path to claude-hooks-monitor repo (default: ../claude-hooks-monitor)
#
# Environment:
#   MEILI_URL        MeiliSearch endpoint (default: http://127.0.0.1:7700)
#   MEILI_KEY        MeiliSearch API key (default: none)
#   MEILI_INDEX      MeiliSearch index (default: hook-events)
#   AB_PROMPT        Override the test prompt
#   AB_MAX_TURNS     Max turns per session (default: 50)
#   COMPACT_WINDOW   Seconds after compaction to count re-reads (default: 120)
#   REPORT_DIR       Directory for report output (default: /tmp/claude-experiment-<timestamp>)
#
# Output:
#   $REPORT_DIR/
#     report.md           — Full analysis report (unbiased)
#     raw/
#       session-a.txt     — Raw Claude output from Session A
#       session-b.txt     — Raw Claude output from Session B
#       events-a.json     — All events for Session A
#       events-b.json     — All events for Session B
#     data/
#       summary-a.json    — Computed metrics for Session A
#       summary-b.json    — Computed metrics for Session B
#       comparison.json   — Side-by-side comparison data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)/claude-hooks-monitor}"
WORKTREE="/tmp/claude-experiment-worktree"
MEILI_URL="${MEILI_URL:-http://127.0.0.1:7700}"
MEILI_KEY="${MEILI_KEY:-}"
MEILI_INDEX="${MEILI_INDEX:-hook-events}"
MAX_TURNS="${AB_MAX_TURNS:-50}"
COMPACT_WINDOW="${COMPACT_WINDOW:-120}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_DIR="${REPORT_DIR:-/tmp/claude-experiment-$TIMESTAMP}"

PROMPT="${AB_PROMPT:-You are doing a thorough code review. Complete ALL of these steps:

1. Read every Go source file in internal/ and cmd/ directories. List each file you read.
2. For each package, explain its exported types and functions.
3. Identify all HTTP handler functions and trace the request flow from handler to storage.
4. Find all error handling patterns — list each error type and how it is handled.
5. Map all configuration sources (flags, env vars, config files) and how they are loaded.
6. Identify any potential bugs, race conditions, or missing error checks.
7. Summarize the full architecture in a detailed report.

Be thorough. Read actual source files, do not guess or summarize from memory.}"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓ %s\033[0m\n" "$*"; }
warn() { printf "  \033[33m⚠ %s\033[0m\n" "$*"; }
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
    warn "MeiliSearch still indexing after ${max_wait}s, proceeding anyway"
}

# Fetch all events for a session by hook_type, sorted by timestamp.
# Paginates past MeiliSearch's 1000-hit limit.
fetch_events() {
    local session_id="$1" hook_type="$2"
    local offset=0 limit=1000
    local all_hits="[]"

    while true; do
        local response hits count
        response=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
            "$(printf '{"filter":"session_id = '\''%s'\'' AND hook_type = '\''%s'\''","sort":["timestamp_unix:asc"],"limit":%d,"offset":%d}' \
            "$session_id" "$hook_type" "$limit" "$offset")")

        hits=$(echo "$response" | jq '.hits')
        count=$(echo "$hits" | jq 'length')

        if [[ "$count" -eq 0 ]]; then break; fi

        all_hits=$(echo "$all_hits $hits" | jq -s '.[0] + .[1]')
        offset=$((offset + count))

        if [[ "$count" -lt "$limit" ]]; then break; fi
    done

    echo "$all_hits"
}

# Fetch ALL events for a session (any hook_type), for raw export.
fetch_all_events() {
    local session_id="$1"
    local offset=0 limit=1000
    local all_hits="[]"

    while true; do
        local response hits count
        response=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
            "$(printf '{"filter":"session_id = '\''%s'\''","sort":["timestamp_unix:asc"],"limit":%d,"offset":%d}' \
            "$session_id" "$limit" "$offset")")

        hits=$(echo "$response" | jq '.hits')
        count=$(echo "$hits" | jq 'length')

        if [[ "$count" -eq 0 ]]; then break; fi

        all_hits=$(echo "$all_hits $hits" | jq -s '.[0] + .[1]')
        offset=$((offset + count))

        if [[ "$count" -lt "$limit" ]]; then break; fi
    done

    echo "$all_hits"
}

# ── Analysis Functions ───────────────────────────────────────────────────────

# Compute all metrics for a session. Outputs a JSON summary.
# Uses temp files + --slurpfile to avoid "Argument list too long" on large event sets.
compute_session_metrics() {
    local session_id="$1" tool_events="$2" compact_events="$3" window="$4"

    local tmp_tools tmp_compacts
    tmp_tools=$(mktemp "$REPORT_DIR/data/.tools-XXXXXX.json")
    tmp_compacts=$(mktemp "$REPORT_DIR/data/.compacts-XXXXXX.json")
    echo "$tool_events" > "$tmp_tools"
    echo "$compact_events" > "$tmp_compacts"

    jq -n \
        --arg sid "$session_id" \
        --slurpfile tools_arr "$tmp_tools" \
        --slurpfile compacts_arr "$tmp_compacts" \
        --argjson window "$window" \
        '
        # --slurpfile wraps in an array; unwrap.
        $tools_arr[0] as $tools |
        $compacts_arr[0] as $compacts |

        # Tool counts.
        ($tools | length) as $total |
        ([$tools[] | select(.tool_name == "Read")]  | length) as $read |
        ([$tools[] | select(.tool_name == "Glob")]  | length) as $glob |
        ([$tools[] | select(.tool_name == "Grep")]  | length) as $grep |
        ([$tools[] | select(.tool_name == "Bash")]  | length) as $bash |
        ([$tools[] | select(.tool_name == "Write")] | length) as $write |
        ([$tools[] | select(.tool_name == "Edit")]  | length) as $edit |
        ([$tools[] | select(.tool_name == "Task")]  | length) as $task |
        ($read + $glob + $grep) as $explore |

        # Batch scans: runs of 3+ consecutive Read/Glob/Grep.
        ([$tools[].tool_name] | . as $names |
            { scans: [], run: 0 } |
            reduce range(0; $names | length) as $i (
                .;
                if ($names[$i] == "Read" or $names[$i] == "Glob" or $names[$i] == "Grep")
                then .run += 1
                else (if .run >= 3 then .scans += [.run] else . end) | .run = 0
                end
            ) |
            if .run >= 3 then .scans += [.run] else . end |
            .scans
        ) as $batch_scans |

        # Compaction analysis.
        ($compacts | length) as $compact_count |
        ([$compacts[].timestamp_unix]) as $compact_times |

        # Per-compaction window analysis.
        ([
            $compact_times[] | . as $ct |
            {
                compact_ts: $ct,
                explore_in_window: ([$tools[] | select(
                    (.tool_name == "Read" or .tool_name == "Glob" or .tool_name == "Grep") and
                    .timestamp_unix >= $ct and .timestamp_unix < ($ct + $window)
                )] | length),
                read_in_window: ([$tools[] | select(
                    .tool_name == "Read" and
                    .timestamp_unix >= $ct and .timestamp_unix < ($ct + $window)
                )] | length),
                glob_in_window: ([$tools[] | select(
                    .tool_name == "Glob" and
                    .timestamp_unix >= $ct and .timestamp_unix < ($ct + $window)
                )] | length),
                grep_in_window: ([$tools[] | select(
                    .tool_name == "Grep" and
                    .timestamp_unix >= $ct and .timestamp_unix < ($ct + $window)
                )] | length),
                total_in_window: ([$tools[] | select(
                    .timestamp_unix >= $ct and .timestamp_unix < ($ct + $window)
                )] | length)
            }
        ]) as $per_compact |

        # Session duration (first to last tool event).
        (if $total > 0 then
            ($tools[-1].timestamp_unix - $tools[0].timestamp_unix)
        else 0 end) as $duration_s |

        # Unique files read (from Read tool events, if file_path available).
        ([$tools[] | select(.tool_name == "Read") | .tool_input.file_path // empty] | unique | length) as $unique_files |

        {
            session_id: $sid,
            duration_s: $duration_s,
            total_tool_calls: $total,
            tools: { read: $read, glob: $glob, grep: $grep, bash: $bash, write: $write, edit: $edit, task: $task },
            exploration: { total: $explore, pct_of_total: (if $total > 0 then ($explore * 1000 / $total | round / 10) else 0 end) },
            unique_files_read: $unique_files,
            batch_scans: {
                count: ($batch_scans | length),
                total_calls: ($batch_scans | add // 0),
                longest: ($batch_scans | max // 0),
                lengths: $batch_scans
            },
            compaction: {
                count: $compact_count,
                post_compact_explore_total: ([$per_compact[].explore_in_window] | add // 0),
                post_compact_explore_avg: (if ($per_compact | length) > 0 then
                    ([$per_compact[].explore_in_window] | add) / ($per_compact | length) | . * 10 | round / 10
                else 0 end),
                post_compact_explore_max: ([$per_compact[].explore_in_window] | max // 0),
                reread_pct: (if $explore > 0 then
                    ([$per_compact[].explore_in_window] | add // 0) / $explore * 100 | . * 10 | round / 10
                else 0 end),
                per_event: $per_compact
            }
        }
        '

    rm -f "$tmp_tools" "$tmp_compacts"
}

# Build comparison JSON from two session summaries.
build_comparison() {
    local data_a="$1" data_b="$2"

    local tmp_a tmp_b
    tmp_a=$(mktemp "$REPORT_DIR/data/.cmp-a-XXXXXX.json")
    tmp_b=$(mktemp "$REPORT_DIR/data/.cmp-b-XXXXXX.json")
    echo "$data_a" > "$tmp_a"
    echo "$data_b" > "$tmp_b"

    jq -n \
        --slurpfile a_arr "$tmp_a" \
        --slurpfile b_arr "$tmp_b" \
        '
        $a_arr[0] as $a | $b_arr[0] as $b |

        def delta($va; $vb):
            { a: $va, b: $vb, diff: ($vb - $va),
              pct: (if $vb != 0 then (($vb - $va) * 1000 / $vb | round / 10) else null end) };

        {
            total_tool_calls: delta($a.total_tool_calls; $b.total_tool_calls),
            exploration_calls: delta($a.exploration.total; $b.exploration.total),
            read_calls: delta($a.tools.read; $b.tools.read),
            glob_calls: delta($a.tools.glob; $b.tools.glob),
            grep_calls: delta($a.tools.grep; $b.tools.grep),
            batch_scan_count: delta($a.batch_scans.count; $b.batch_scans.count),
            batch_scan_calls: delta($a.batch_scans.total_calls; $b.batch_scans.total_calls),
            compact_count: delta($a.compaction.count; $b.compaction.count),
            post_compact_explore: delta($a.compaction.post_compact_explore_total; $b.compaction.post_compact_explore_total),
            duration_s: delta($a.duration_s; $b.duration_s),
            unique_files_read: delta($a.unique_files_read; $b.unique_files_read)
        }
        '

    rm -f "$tmp_a" "$tmp_b"
}

# ── Report Generation ────────────────────────────────────────────────────────

generate_report() {
    local data_a="$1" data_b="$2" comparison="$3"
    local session_a_id session_b_id

    session_a_id=$(echo "$data_a" | jq -r '.session_id')
    session_b_id=$(echo "$data_b" | jq -r '.session_id')

    cat <<REPORT_HEADER
# CLAUDE.md Impact Experiment Report

**Generated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')
**Repo under test:** $REPO
**Max turns per session:** $MAX_TURNS
**Post-compaction window:** ${COMPACT_WINDOW}s

## Experiment Design

Two Claude Code sessions were run against the same codebase with the same prompt
and the same max-turn limit. The only controlled difference:

| | Session A | Session B |
|---|---|---|
| **Condition** | CLAUDE.md files present | CLAUDE.md files removed |
| **Session ID** | \`$session_a_id\` | \`$session_b_id\` |
| **Codebase** | Original repo | Git worktree (identical code) |

**Prompt used:**
\`\`\`
${PROMPT:0:500}
\`\`\`

---

## 1. Tool Usage Overview

REPORT_HEADER

    # Table of tool counts.
    printf "| Metric | Session A | Session B | Δ (B − A) | Δ%% of B |\n"
    printf "|--------|----------:|----------:|----------:|---------:|\n"

    # Helper: print a comparison row from the comparison JSON.
    print_row() {
        local label="$1" key="$2"
        local va vb diff pct
        va=$(echo "$comparison" | jq ".$key.a")
        vb=$(echo "$comparison" | jq ".$key.b")
        diff=$(echo "$comparison" | jq ".$key.diff")
        pct=$(echo "$comparison" | jq ".$key.pct // \"n/a\"")
        printf "| %s | %s | %s | %+d | %s |\n" "$label" "$va" "$vb" "$diff" "$pct"
    }

    print_row "Total tool calls" "total_tool_calls"
    print_row "Exploration (Read+Glob+Grep)" "exploration_calls"
    print_row "Read" "read_calls"
    print_row "Glob" "glob_calls"
    print_row "Grep" "grep_calls"
    print_row "Unique files read" "unique_files_read"
    print_row "Duration (seconds)" "duration_s"

    echo ""

    # Exploration percentage.
    local explore_pct_a explore_pct_b
    explore_pct_a=$(echo "$data_a" | jq '.exploration.pct_of_total')
    explore_pct_b=$(echo "$data_b" | jq '.exploration.pct_of_total')
    printf "Exploration as %% of total: Session A = %s%%, Session B = %s%%\n" "$explore_pct_a" "$explore_pct_b"

    cat <<'SECTION2'

---

## 2. Batch Scan Analysis

A "batch scan" is a run of 3 or more consecutive exploration calls (Read, Glob,
or Grep) without any other tool call in between. High batch scan counts suggest
the model is scanning the codebase to build context rather than working from
existing knowledge.

SECTION2

    printf "| Metric | Session A | Session B | Δ (B − A) |\n"
    printf "|--------|----------:|----------:|----------:|\n"
    print_row "Batch scans (≥3 consecutive)" "batch_scan_count"
    print_row "Calls within batch scans" "batch_scan_calls"

    local longest_a longest_b
    longest_a=$(echo "$data_a" | jq '.batch_scans.longest')
    longest_b=$(echo "$data_b" | jq '.batch_scans.longest')
    printf "| Longest single batch | %s | %s | %+d |\n" "$longest_a" "$longest_b" "$((longest_b - longest_a))"

    cat <<'SECTION3'

---

## 3. Context Compaction Analysis

Context compaction occurs when the conversation history exceeds the model's
context window. The system compresses prior messages, which can cause the model
to lose awareness of previously-read files and need to re-read them.

SECTION3

    local compact_a compact_b
    compact_a=$(echo "$data_a" | jq '.compaction.count')
    compact_b=$(echo "$data_b" | jq '.compaction.count')

    printf "| Metric | Session A | Session B | Δ (B − A) |\n"
    printf "|--------|----------:|----------:|----------:|\n"
    printf "| Compaction events | %s | %s | %+d |\n" "$compact_a" "$compact_b" "$((compact_b - compact_a))"

    if [[ "$compact_a" -gt 0 || "$compact_b" -gt 0 ]]; then
        print_row "Post-compact exploration calls" "post_compact_explore"

        local reread_a reread_b
        reread_a=$(echo "$data_a" | jq '.compaction.reread_pct')
        reread_b=$(echo "$data_b" | jq '.compaction.reread_pct')
        printf "| Re-read ratio | %s%% | %s%% | — |\n" "$reread_a" "$reread_b"

        local avg_a avg_b max_a max_b
        avg_a=$(echo "$data_a" | jq '.compaction.post_compact_explore_avg')
        avg_b=$(echo "$data_b" | jq '.compaction.post_compact_explore_avg')
        max_a=$(echo "$data_a" | jq '.compaction.post_compact_explore_max')
        max_b=$(echo "$data_b" | jq '.compaction.post_compact_explore_max')
        printf "| Avg exploration per compaction | %s | %s | — |\n" "$avg_a" "$avg_b"
        printf "| Max exploration per compaction | %s | %s | — |\n" "$max_a" "$max_b"

        echo ""
        echo "### Per-compaction breakdown"
        echo ""

        # Session A compaction details.
        if [[ "$compact_a" -gt 0 ]]; then
            echo "**Session A:**"
            echo ""
            printf "| # | Exploration | Read | Glob | Grep | Total in window |\n"
            printf "|---|------------:|-----:|-----:|-----:|----------------:|\n"
            local i=0
            while [[ $i -lt $compact_a ]]; do
                local e r g gr t
                e=$(echo "$data_a" | jq ".compaction.per_event[$i].explore_in_window")
                r=$(echo "$data_a" | jq ".compaction.per_event[$i].read_in_window")
                g=$(echo "$data_a" | jq ".compaction.per_event[$i].glob_in_window")
                gr=$(echo "$data_a" | jq ".compaction.per_event[$i].grep_in_window")
                t=$(echo "$data_a" | jq ".compaction.per_event[$i].total_in_window")
                printf "| %d | %s | %s | %s | %s | %s |\n" "$((i+1))" "$e" "$r" "$g" "$gr" "$t"
                i=$((i + 1))
            done
            echo ""
        fi

        # Session B compaction details.
        if [[ "$compact_b" -gt 0 ]]; then
            echo "**Session B:**"
            echo ""
            printf "| # | Exploration | Read | Glob | Grep | Total in window |\n"
            printf "|---|------------:|-----:|-----:|-----:|----------------:|\n"
            local i=0
            while [[ $i -lt $compact_b ]]; do
                local e r g gr t
                e=$(echo "$data_b" | jq ".compaction.per_event[$i].explore_in_window")
                r=$(echo "$data_b" | jq ".compaction.per_event[$i].read_in_window")
                g=$(echo "$data_b" | jq ".compaction.per_event[$i].glob_in_window")
                gr=$(echo "$data_b" | jq ".compaction.per_event[$i].grep_in_window")
                t=$(echo "$data_b" | jq ".compaction.per_event[$i].total_in_window")
                printf "| %d | %s | %s | %s | %s | %s |\n" "$((i+1))" "$e" "$r" "$g" "$gr" "$t"
                i=$((i + 1))
            done
            echo ""
        fi
    else
        echo ""
        echo "*Neither session triggered context compaction. The sessions may not have"
        echo "been long enough. Consider increasing AB_MAX_TURNS or using a more"
        echo "exploration-heavy prompt.*"
    fi

    cat <<'SECTION4'

---

## 4. Observations

SECTION4

    # Auto-generate neutral observations based on the data.
    local total_a total_b explore_a explore_b
    total_a=$(echo "$comparison" | jq '.total_tool_calls.a')
    total_b=$(echo "$comparison" | jq '.total_tool_calls.b')
    explore_a=$(echo "$comparison" | jq '.exploration_calls.a')
    explore_b=$(echo "$comparison" | jq '.exploration_calls.b')

    echo "The following observations are automatically derived from the data above."
    echo "They describe what was measured, not why. Interpretation is left to the reader."
    echo ""

    # Total tool calls.
    if [[ "$total_a" -lt "$total_b" ]]; then
        echo "- Session A (with CLAUDE.md) used **fewer total tool calls** ($total_a vs $total_b)."
    elif [[ "$total_a" -gt "$total_b" ]]; then
        echo "- Session A (with CLAUDE.md) used **more total tool calls** ($total_a vs $total_b)."
    else
        echo "- Both sessions used the **same number of total tool calls** ($total_a)."
    fi

    # Exploration calls.
    if [[ "$explore_a" -lt "$explore_b" ]]; then
        echo "- Session A made **fewer exploration calls** ($explore_a vs $explore_b)."
    elif [[ "$explore_a" -gt "$explore_b" ]]; then
        echo "- Session A made **more exploration calls** ($explore_a vs $explore_b)."
    else
        echo "- Both sessions made the **same number of exploration calls** ($explore_a)."
    fi

    # Batch scans.
    local batch_a batch_b
    batch_a=$(echo "$data_a" | jq '.batch_scans.count')
    batch_b=$(echo "$data_b" | jq '.batch_scans.count')
    if [[ "$batch_a" -lt "$batch_b" ]]; then
        echo "- Session A had **fewer batch scans** ($batch_a vs $batch_b)."
    elif [[ "$batch_a" -gt "$batch_b" ]]; then
        echo "- Session A had **more batch scans** ($batch_a vs $batch_b)."
    elif [[ "$batch_a" -gt 0 ]]; then
        echo "- Both sessions had the **same number of batch scans** ($batch_a)."
    fi

    # Compaction.
    if [[ "$compact_a" -gt 0 || "$compact_b" -gt 0 ]]; then
        if [[ "$compact_a" -ne "$compact_b" ]]; then
            echo "- Compaction events differed: Session A had $compact_a, Session B had $compact_b."
        else
            echo "- Both sessions triggered $compact_a compaction event(s)."
        fi

        local post_a post_b
        post_a=$(echo "$data_a" | jq '.compaction.post_compact_explore_total')
        post_b=$(echo "$data_b" | jq '.compaction.post_compact_explore_total')
        if [[ "$post_a" -lt "$post_b" ]]; then
            echo "- After compaction, Session A made **fewer exploration calls** ($post_a vs $post_b)."
        elif [[ "$post_a" -gt "$post_b" ]]; then
            echo "- After compaction, Session A made **more exploration calls** ($post_a vs $post_b)."
        elif [[ "$post_a" -gt 0 ]]; then
            echo "- Both sessions made the same number of post-compaction exploration calls ($post_a)."
        fi
    fi

    cat <<'SECTION5'

---

## 5. Limitations

- **Single run:** This report is based on one pair of sessions. Results may vary
  across runs due to model non-determinism.
- **Prompt sensitivity:** Different prompts produce different exploration patterns.
  Results apply to the specific prompt used, not to all workloads.
- **Confounds:** Session B runs in a git worktree. While the code is identical,
  subtle differences (detached HEAD, different absolute paths) could affect
  behavior.
- **Compaction timing:** The post-compaction window is a fixed duration. Some
  re-reads may occur outside this window; some calls within the window may be
  unrelated to re-reading.
- **No cost data:** Token usage is not directly measured. Tool call counts are a
  proxy for cost, not an exact measure.

---

*Report generated by run-full-experiment.sh*
*Data source: MeiliSearch at MEILI_URL*
SECTION5
}

# ── Preflight ────────────────────────────────────────────────────────────────

log "Preflight checks"

if [[ -n "${CLAUDECODE:-}" ]]; then
    fail "Cannot run inside a Claude Code session. Run from a plain terminal."
fi
ok "Not inside Claude Code"

if ! command -v claude &>/dev/null; then
    fail "claude CLI not found in PATH"
fi
ok "claude CLI: $(claude --version 2>/dev/null | head -1)"

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

# ── Setup report directory ───────────────────────────────────────────────────

log "Setting up report directory"
mkdir -p "$REPORT_DIR/raw" "$REPORT_DIR/data"
ok "Report directory: $REPORT_DIR"

# ── Experiment info ──────────────────────────────────────────────────────────

log "Experiment configuration"
echo "  Max turns:         $MAX_TURNS"
echo "  Compact window:    ${COMPACT_WINDOW}s"
echo "  Report dir:        $REPORT_DIR"
echo "  Prompt:            ${PROMPT:0:100}..."

# Save experiment config.
jq -n \
    --arg repo "$REPO" \
    --arg prompt "$PROMPT" \
    --argjson max_turns "$MAX_TURNS" \
    --argjson compact_window "$COMPACT_WINDOW" \
    --arg timestamp "$TIMESTAMP" \
    --arg meili_url "$MEILI_URL" \
    '{ repo: $repo, prompt: $prompt, max_turns: $max_turns,
       compact_window: $compact_window, timestamp: $timestamp,
       meili_url: $meili_url }' \
    > "$REPORT_DIR/data/config.json"

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

# Copy build artifacts required for hook events.
if [[ -f "$REPO/hooks/hook-client" ]]; then
    mkdir -p "$WORKTREE/hooks"
    cp "$REPO/hooks/hook-client" "$WORKTREE/hooks/hook-client"
    if [[ -f "$REPO/hooks/hook_monitor.conf" ]]; then
        cp "$REPO/hooks/hook_monitor.conf" "$WORKTREE/hooks/hook_monitor.conf"
    fi
    ok "Copied hook-client (and config) to worktree"
else
    warn "hooks/hook-client not found in $REPO — build it first (make build)"
    warn "Session B will NOT emit events without it!"
fi

# ── Run Session A ────────────────────────────────────────────────────────────

log "Session A — WITH CLAUDE.md"
echo "  Directory: $REPO"
echo "  Max turns: $MAX_TURNS"

SESSION_A_START=$(date +%s)
(
    cd "$REPO"
    env -u CLAUDECODE claude -p "$PROMPT" \
        --output-format text \
        --max-turns "$MAX_TURNS" \
        2>&1
) > "$REPORT_DIR/raw/session-a.txt" || true
SESSION_A_END=$(date +%s)

ok "Session A complete ($(( SESSION_A_END - SESSION_A_START ))s wall clock)"

echo "  Waiting for MeiliSearch indexing..."
sleep 5
wait_for_indexing

# ── Identify Session A ──────────────────────────────────────────────────────

log "Identifying Session A"
SESSIONS_AFTER_A=$(get_session_ids)
SESSION_A_ID=$(comm -13 <(echo "$SESSIONS_BEFORE" | grep -v '^$') <(echo "$SESSIONS_AFTER_A" | grep -v '^$') | head -1)

if [[ -z "$SESSION_A_ID" ]]; then
    warn "Could not detect Session A's ID. Will try auto-detection after Session B."
else
    ok "Session A ID: $SESSION_A_ID"
fi

# ── Run Session B ────────────────────────────────────────────────────────────

log "Session B — WITHOUT CLAUDE.md"
echo "  Directory: $WORKTREE"
echo "  Max turns: $MAX_TURNS"

SESSION_B_START=$(date +%s)
(
    cd "$WORKTREE"
    env -u CLAUDECODE claude -p "$PROMPT" \
        --output-format text \
        --max-turns "$MAX_TURNS" \
        2>&1
) > "$REPORT_DIR/raw/session-b.txt" || true
SESSION_B_END=$(date +%s)

ok "Session B complete ($(( SESSION_B_END - SESSION_B_START ))s wall clock)"

echo "  Waiting for MeiliSearch indexing..."
sleep 5
wait_for_indexing

# ── Identify Session B ──────────────────────────────────────────────────────

log "Identifying Session B"
SESSIONS_AFTER_B=$(get_session_ids)
SESSION_B_ID=$(comm -13 <(echo "$SESSIONS_AFTER_A" | grep -v '^$') <(echo "$SESSIONS_AFTER_B" | grep -v '^$') | head -1)

if [[ -z "$SESSION_B_ID" ]]; then
    warn "Could not detect Session B's ID. Falling back to auto-detection."
    detected=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
        '{"facets":["session_id"],"limit":0}' \
        | jq -r '.facetDistribution.session_id // {} | keys[]')

    count=$(echo "$detected" | grep -c . || true)
    if [[ "$count" -lt 2 ]]; then
        fail "Cannot identify sessions. Need at least 2 in MeiliSearch, found $count."
    fi

    # Take the two most recent by earliest event timestamp.
    session_times=()
    while IFS= read -r sid; do
        ts=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
            "$(printf '{"filter":"session_id = '\''%s'\''","sort":["timestamp_unix:asc"],"limit":1,"attributesToRetrieve":["timestamp_unix"]}' "$sid")" \
            | jq '.hits[0].timestamp_unix // 0')
        session_times+=("$ts:$sid")
    done <<< "$detected"

    sorted=$(printf '%s\n' "${session_times[@]}" | grep -v '^0:' | sort -t: -k1 -rn | head -2)
    SESSION_B_ID=$(echo "$sorted" | head -1 | cut -d: -f2-)
    SESSION_A_ID=$(echo "$sorted" | tail -1 | cut -d: -f2-)
    warn "Auto-detected: A=$SESSION_A_ID, B=$SESSION_B_ID"
fi

ok "Session A: $SESSION_A_ID"
ok "Session B: $SESSION_B_ID"

# ── Gather data ──────────────────────────────────────────────────────────────

log "Gathering event data from MeiliSearch"

echo "  Fetching all events for Session A..."
ALL_EVENTS_A=$(fetch_all_events "$SESSION_A_ID")
echo "$ALL_EVENTS_A" | jq '.' > "$REPORT_DIR/raw/events-a.json"
ok "Session A: $(echo "$ALL_EVENTS_A" | jq 'length') total events"

echo "  Fetching all events for Session B..."
ALL_EVENTS_B=$(fetch_all_events "$SESSION_B_ID")
echo "$ALL_EVENTS_B" | jq '.' > "$REPORT_DIR/raw/events-b.json"
ok "Session B: $(echo "$ALL_EVENTS_B" | jq 'length') total events"

# Extract PreToolUse and PreCompact subsets.
TOOLS_A=$(echo "$ALL_EVENTS_A" | jq '[.[] | select(.hook_type == "PreToolUse")]')
TOOLS_B=$(echo "$ALL_EVENTS_B" | jq '[.[] | select(.hook_type == "PreToolUse")]')
COMPACTS_A=$(echo "$ALL_EVENTS_A" | jq '[.[] | select(.hook_type == "PreCompact")]')
COMPACTS_B=$(echo "$ALL_EVENTS_B" | jq '[.[] | select(.hook_type == "PreCompact")]')

ok "Session A: $(echo "$TOOLS_A" | jq 'length') tool events, $(echo "$COMPACTS_A" | jq 'length') compaction events"
ok "Session B: $(echo "$TOOLS_B" | jq 'length') tool events, $(echo "$COMPACTS_B" | jq 'length') compaction events"

# ── Compute metrics ──────────────────────────────────────────────────────────

log "Computing metrics"

DATA_A=$(compute_session_metrics "$SESSION_A_ID" "$TOOLS_A" "$COMPACTS_A" "$COMPACT_WINDOW")
echo "$DATA_A" | jq '.' > "$REPORT_DIR/data/summary-a.json"
ok "Session A metrics computed"

DATA_B=$(compute_session_metrics "$SESSION_B_ID" "$TOOLS_B" "$COMPACTS_B" "$COMPACT_WINDOW")
echo "$DATA_B" | jq '.' > "$REPORT_DIR/data/summary-b.json"
ok "Session B metrics computed"

COMPARISON=$(build_comparison "$DATA_A" "$DATA_B")
echo "$COMPARISON" | jq '.' > "$REPORT_DIR/data/comparison.json"
ok "Comparison data built"

# ── Generate report ──────────────────────────────────────────────────────────

log "Generating report"

generate_report "$DATA_A" "$DATA_B" "$COMPARISON" > "$REPORT_DIR/report.md"
ok "Report written to $REPORT_DIR/report.md"

# ── Cleanup ──────────────────────────────────────────────────────────────────

log "Cleanup"
git -C "$REPO" worktree remove "$WORKTREE" --force 2>/dev/null \
    && ok "Worktree removed" \
    || warn "Could not remove worktree (remove manually: git -C $REPO worktree remove $WORKTREE)"

# ── Summary ──────────────────────────────────────────────────────────────────

log "Experiment complete"
echo ""
echo "  Report:        $REPORT_DIR/report.md"
echo "  Raw output:    $REPORT_DIR/raw/"
echo "  Computed data: $REPORT_DIR/data/"
echo ""
echo "  Quick view:    cat $REPORT_DIR/report.md"
echo ""
