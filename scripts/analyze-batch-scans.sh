#!/usr/bin/env bash
# Analyze batch scans: compare tool usage between two Claude Code sessions.
# Queries MeiliSearch to detect "batch scans" (3+ consecutive Read/Glob/Grep)
# and produces a comparison report showing CLAUDE.md impact.
#
# Usage:
#   ./scripts/analyze-batch-scans.sh [session_a] [session_b]
#   # With no args: auto-detects the two most recent sessions.
#
# Environment:
#   MEILI_URL   MeiliSearch endpoint (default: http://localhost:7700)
#   MEILI_KEY   MeiliSearch API key (default: none)
#   MEILI_INDEX Index name (default: hook-events)

set -euo pipefail

MEILI_URL="${MEILI_URL:-http://127.0.0.1:7700}"
MEILI_KEY="${MEILI_KEY:-}"
MEILI_INDEX="${MEILI_INDEX:-hook-events}"

# ── Helpers ──────────────────────────────────────────────────────────────────

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

check_meili() {
    if ! curl -sf "$MEILI_URL/health" >/dev/null 2>&1; then
        echo "ERROR: MeiliSearch is not reachable at $MEILI_URL" >&2
        exit 1
    fi
}

# Fetch all PreToolUse events for a session, sorted by timestamp.
# MeiliSearch caps at 1000 per request, so we paginate.
fetch_events() {
    local session_id="$1"
    local offset=0
    local limit=1000
    local all_hits="[]"

    while true; do
        local response
        response=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
            "$(printf '{"filter":"session_id = '\''%s'\'' AND hook_type = '\''PreToolUse'\''","sort":["timestamp_unix:asc"],"limit":%d,"offset":%d,"attributesToRetrieve":["tool_name","timestamp_unix"]}' \
            "$session_id" "$limit" "$offset")")

        local hits
        hits=$(echo "$response" | jq '.hits')
        local count
        count=$(echo "$hits" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            break
        fi

        all_hits=$(echo "$all_hits $hits" | jq -s '.[0] + .[1]')
        offset=$((offset + count))

        if [[ "$count" -lt "$limit" ]]; then
            break
        fi
    done

    echo "$all_hits"
}

# Auto-detect the two most recent sessions by fetching facets.
auto_detect_sessions() {
    local response
    response=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
        '{"facets":["session_id"],"limit":0}')

    local sessions
    sessions=$(echo "$response" | jq -r '.facetDistribution.session_id // {} | keys[]')

    local count
    count=$(echo "$sessions" | grep -c . || true)

    if [[ "$count" -lt 2 ]]; then
        echo "ERROR: Need at least 2 sessions in MeiliSearch, found $count" >&2
        echo "Run two Claude Code sessions first, then re-run this script." >&2
        exit 1
    fi

    # For each session, get its earliest timestamp to sort chronologically.
    local session_times=()
    while IFS= read -r sid; do
        local first_ts
        first_ts=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
            "$(printf '{"filter":"session_id = '\''%s'\''","sort":["timestamp_unix:asc"],"limit":1,"attributesToRetrieve":["timestamp_unix"]}' "$sid")" \
            | jq '.hits[0].timestamp_unix // 0')
        session_times+=("$first_ts:$sid")
    done <<< "$sessions"

    # Sort by timestamp descending, take the two most recent.
    # Filter out sessions with no events (first_ts=0) to avoid selecting stale entries.
    local sorted
    sorted=$(printf '%s\n' "${session_times[@]}" | grep -v '^0:' | sort -t: -k1 -rn | head -2)

    # First line = most recent (session B / without), second = second most recent (session A / with)
    local session_b session_a
    session_b=$(echo "$sorted" | head -1 | cut -d: -f2-)
    session_a=$(echo "$sorted" | tail -1 | cut -d: -f2-)

    echo "$session_a"
    echo "$session_b"
}

# ── Analysis ─────────────────────────────────────────────────────────────────

# Analyze a single session: count tools, detect batch scans.
# Output: JSON with counts and batch scan info.
analyze_session() {
    local session_id="$1"
    local events="$2"

    local total
    total=$(echo "$events" | jq 'length')

    # Count per tool_name.
    local read_count glob_count grep_count bash_count write_count edit_count task_count
    read_count=$(echo "$events"  | jq '[.[] | select(.tool_name == "Read")]  | length')
    glob_count=$(echo "$events"  | jq '[.[] | select(.tool_name == "Glob")]  | length')
    grep_count=$(echo "$events"  | jq '[.[] | select(.tool_name == "Grep")]  | length')
    bash_count=$(echo "$events"  | jq '[.[] | select(.tool_name == "Bash")]  | length')
    write_count=$(echo "$events" | jq '[.[] | select(.tool_name == "Write")] | length')
    edit_count=$(echo "$events"  | jq '[.[] | select(.tool_name == "Edit")]  | length')
    task_count=$(echo "$events"  | jq '[.[] | select(.tool_name == "Task")]  | length')

    # Detect batch scans: runs of 3+ consecutive Read/Glob/Grep calls.
    local batch_info
    batch_info=$(echo "$events" | jq '
        [.[] | .tool_name] as $tools |
        { scans: [], current_run: 0 } |
        reduce range(0; $tools | length) as $i (
            .;
            if ($tools[$i] == "Read" or $tools[$i] == "Glob" or $tools[$i] == "Grep") then
                .current_run += 1
            else
                if .current_run >= 3 then
                    .scans += [.current_run]
                else . end |
                .current_run = 0
            end
        ) |
        # Flush final run.
        if .current_run >= 3 then .scans += [.current_run] else . end |
        {
            batch_scan_count: (.scans | length),
            batch_scan_calls: (.scans | add // 0),
            longest_scan: (.scans | max // 0),
            scan_lengths: .scans
        }
    ')

    local batch_scan_count batch_scan_calls longest_scan
    batch_scan_count=$(echo "$batch_info" | jq '.batch_scan_count')
    batch_scan_calls=$(echo "$batch_info" | jq '.batch_scan_calls')
    longest_scan=$(echo "$batch_info" | jq '.longest_scan')

    # Output structured data.
    jq -n \
        --arg sid "$session_id" \
        --argjson total "$total" \
        --argjson read "$read_count" \
        --argjson glob "$glob_count" \
        --argjson grep "$grep_count" \
        --argjson bash "$bash_count" \
        --argjson write "$write_count" \
        --argjson edit "$edit_count" \
        --argjson task "$task_count" \
        --argjson batch_count "$batch_scan_count" \
        --argjson batch_calls "$batch_scan_calls" \
        --argjson longest "$longest_scan" \
        '{
            session_id: $sid,
            total: $total,
            read: $read, glob: $glob, grep: $grep,
            bash: $bash, write: $write, edit: $edit, task: $task,
            batch_scan_count: $batch_count,
            batch_scan_calls: $batch_calls,
            longest_scan: $longest
        }'
}

# Pretty-print a session report block.
print_session() {
    local label="$1" data="$2"
    local sid total read glob grep bash write edit task batch_count batch_calls longest

    sid=$(echo "$data" | jq -r '.session_id')
    total=$(echo "$data" | jq '.total')
    read=$(echo "$data" | jq '.read')
    glob=$(echo "$data" | jq '.glob')
    grep=$(echo "$data" | jq '.grep')
    bash=$(echo "$data" | jq '.bash')
    write=$(echo "$data" | jq '.write')
    edit=$(echo "$data" | jq '.edit')
    task=$(echo "$data" | jq '.task')
    batch_count=$(echo "$data" | jq '.batch_scan_count')
    batch_calls=$(echo "$data" | jq '.batch_scan_calls')
    longest=$(echo "$data" | jq '.longest_scan')

    local exploration=$((read + glob + grep))

    printf "%s: %s\n" "$label" "$sid"
    printf "  Total tool calls:    %d\n" "$total"
    printf "  Read calls:          %d\n" "$read"
    printf "  Glob calls:          %d\n" "$glob"
    printf "  Grep calls:          %d\n" "$grep"
    printf "  Exploration total:   %d\n" "$exploration"
    printf "  Bash calls:          %d\n" "$bash"
    printf "  Write calls:         %d\n" "$write"
    printf "  Edit calls:          %d\n" "$edit"
    printf "  Task calls:          %d\n" "$task"
    printf "  Batch scans (≥3):    %d (%d calls, longest: %d)\n" "$batch_count" "$batch_calls" "$longest"
}

# Print comparison delta between two sessions.
print_comparison() {
    local data_a="$1" data_b="$2"

    local read_a read_b glob_a glob_b grep_a grep_b total_a total_b
    read_a=$(echo "$data_a" | jq '.read')
    read_b=$(echo "$data_b" | jq '.read')
    glob_a=$(echo "$data_a" | jq '.glob')
    glob_b=$(echo "$data_b" | jq '.glob')
    grep_a=$(echo "$data_a" | jq '.grep')
    grep_b=$(echo "$data_b" | jq '.grep')
    total_a=$(echo "$data_a" | jq '.total')
    total_b=$(echo "$data_b" | jq '.total')

    local explore_a=$((read_a + glob_a + grep_a))
    local explore_b=$((read_b + glob_b + grep_b))

    local batch_a batch_b
    batch_a=$(echo "$data_a" | jq '.batch_scan_count')
    batch_b=$(echo "$data_b" | jq '.batch_scan_count')

    # Helper: print delta line. Shows (B − A) and % relative to B (the no-CLAUDE.md baseline).
    delta_line() {
        local label="$1" val_a="$2" val_b="$3"
        local diff=$((val_b - val_a))
        if [[ "$val_b" -eq 0 && "$val_a" -eq 0 ]]; then
            printf "  %-22s  0 (no data)\n" "$label:"
        elif [[ "$val_b" -eq 0 ]]; then
            printf "  %-22s %+d (B had none)\n" "$label:" "$diff"
        else
            local pct=$((diff * 100 / val_b))
            printf "  %-22s A=%d  B=%d  Δ=%+d (%+d%% of B)\n" "$label:" "$val_a" "$val_b" "$diff" "$pct"
        fi
    }

    echo "=== Comparison ==="
    echo "  A = with CLAUDE.md, B = without CLAUDE.md"
    echo "  Positive Δ = B used more calls → CLAUDE.md saved work"
    echo ""
    delta_line "Read" "$read_a" "$read_b"
    delta_line "Glob" "$glob_a" "$glob_b"
    delta_line "Grep" "$grep_a" "$grep_b"
    delta_line "Exploration total" "$explore_a" "$explore_b"
    delta_line "Total tool calls" "$total_a" "$total_b"
    delta_line "Batch scans" "$batch_a" "$batch_b"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    check_meili

    local session_a session_b

    if [[ $# -ge 2 ]]; then
        session_a="$1"
        session_b="$2"
    else
        echo "Auto-detecting the two most recent sessions..."
        local detected
        detected=$(auto_detect_sessions)
        session_a=$(echo "$detected" | head -1)
        session_b=$(echo "$detected" | tail -1)
        echo "  Session A (with CLAUDE.md):    $session_a"
        echo "  Session B (without CLAUDE.md): $session_b"
        echo ""
        echo "Tip: pass session IDs explicitly if auto-detection picked wrong sessions."
        echo ""
    fi

    echo "Fetching events for Session A..."
    local events_a
    events_a=$(fetch_events "$session_a")

    echo "Fetching events for Session B..."
    local events_b
    events_b=$(fetch_events "$session_b")

    echo ""

    local data_a data_b
    data_a=$(analyze_session "$session_a" "$events_a")
    data_b=$(analyze_session "$session_b" "$events_b")

    echo "=== CLAUDE.md Impact Analysis ==="
    echo ""
    print_session "Session A (with CLAUDE.md)   " "$data_a"
    echo ""
    print_session "Session B (without CLAUDE.md)" "$data_b"
    echo ""
    print_comparison "$data_a" "$data_b"
}

main "$@"
