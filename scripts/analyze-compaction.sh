#!/usr/bin/env bash
# Analyze compaction impact: measure the "re-read penalty" after context compaction.
# Queries MeiliSearch for PreCompact and PreToolUse events, then calculates how many
# exploration calls (Read/Glob/Grep) occur in a window after each compaction event.
#
# Usage:
#   ./scripts/analyze-compaction.sh [session_a] [session_b]
#   # With no args: auto-detects the two most recent sessions.
#
# Environment:
#   MEILI_URL       MeiliSearch endpoint (default: http://127.0.0.1:7700)
#   MEILI_KEY       MeiliSearch API key (default: none)
#   MEILI_INDEX     Index name (default: hook-events)
#   COMPACT_WINDOW  Seconds after compaction to count re-reads (default: 120)

set -euo pipefail

MEILI_URL="${MEILI_URL:-http://127.0.0.1:7700}"
MEILI_KEY="${MEILI_KEY:-}"
MEILI_INDEX="${MEILI_INDEX:-hook-events}"
COMPACT_WINDOW="${COMPACT_WINDOW:-120}"

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

# Fetch events for a session by hook_type, sorted by timestamp.
# Paginates past MeiliSearch's 1000-hit limit.
fetch_events() {
    local session_id="$1" hook_type="$2"
    local offset=0
    local limit=1000
    local all_hits="[]"

    while true; do
        local response
        response=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
            "$(printf '{"filter":"session_id = '\''%s'\'' AND hook_type = '\''%s'\''","sort":["timestamp_unix:asc"],"limit":%d,"offset":%d}' \
            "$session_id" "$hook_type" "$limit" "$offset")")

        local hits count
        hits=$(echo "$response" | jq '.hits')
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
        exit 1
    fi

    local session_times=()
    while IFS= read -r sid; do
        local first_ts
        first_ts=$(curl_meili POST "/indexes/$MEILI_INDEX/search" \
            "$(printf '{"filter":"session_id = '\''%s'\''","sort":["timestamp_unix:asc"],"limit":1,"attributesToRetrieve":["timestamp_unix"]}' "$sid")" \
            | jq '.hits[0].timestamp_unix // 0')
        session_times+=("$first_ts:$sid")
    done <<< "$sessions"

    local sorted
    sorted=$(printf '%s\n' "${session_times[@]}" | grep -v '^0:' | sort -t: -k1 -rn | head -2)

    local session_b session_a
    session_b=$(echo "$sorted" | head -1 | cut -d: -f2-)
    session_a=$(echo "$sorted" | tail -1 | cut -d: -f2-)

    echo "$session_a"
    echo "$session_b"
}

# ── Analysis ─────────────────────────────────────────────────────────────────

# Analyze a single session's compaction behavior.
# Returns JSON with compaction count, post-compaction re-read stats, and totals.
analyze_session() {
    local session_id="$1"
    local tool_events="$2"
    local compact_events="$3"
    local window="$4"

    local total_tools compact_count
    total_tools=$(echo "$tool_events" | jq 'length')
    compact_count=$(echo "$compact_events" | jq 'length')

    # Count exploration calls (Read/Glob/Grep).
    local explore_total
    explore_total=$(echo "$tool_events" | jq '[.[] | select(.tool_name == "Read" or .tool_name == "Glob" or .tool_name == "Grep")] | length')

    # Per-tool counts.
    local read_count glob_count grep_count
    read_count=$(echo "$tool_events" | jq '[.[] | select(.tool_name == "Read")] | length')
    glob_count=$(echo "$tool_events" | jq '[.[] | select(.tool_name == "Glob")] | length')
    grep_count=$(echo "$tool_events" | jq '[.[] | select(.tool_name == "Grep")] | length')

    # For each compaction event, count exploration calls in the window after it.
    local post_compact_data
    post_compact_data=$(jq -n \
        --argjson tools "$tool_events" \
        --argjson compacts "$compact_events" \
        --argjson window "$window" \
        '
        [$compacts[].timestamp_unix] as $compact_times |
        [
            $compact_times[] | . as $ct |
            {
                compact_ts: $ct,
                window_end: ($ct + $window),
                reads_in_window: ([$tools[] | select(
                    (.tool_name == "Read" or .tool_name == "Glob" or .tool_name == "Grep") and
                    .timestamp_unix >= $ct and
                    .timestamp_unix < ($ct + $window)
                )] | length),
                all_in_window: ([$tools[] | select(
                    .timestamp_unix >= $ct and
                    .timestamp_unix < ($ct + $window)
                )] | length),
                read_in_window: ([$tools[] | select(
                    .tool_name == "Read" and
                    .timestamp_unix >= $ct and
                    .timestamp_unix < ($ct + $window)
                )] | length),
                glob_in_window: ([$tools[] | select(
                    .tool_name == "Glob" and
                    .timestamp_unix >= $ct and
                    .timestamp_unix < ($ct + $window)
                )] | length),
                grep_in_window: ([$tools[] | select(
                    .tool_name == "Grep" and
                    .timestamp_unix >= $ct and
                    .timestamp_unix < ($ct + $window)
                )] | length)
            }
        ]
        ')

    # Aggregate post-compaction stats.
    local total_post_reads avg_post_reads max_post_reads
    total_post_reads=$(echo "$post_compact_data" | jq '[.[].reads_in_window] | add // 0')
    avg_post_reads=$(echo "$post_compact_data" | jq 'if length == 0 then 0 else ([.[].reads_in_window] | add) / length | . * 10 | round / 10 end')
    max_post_reads=$(echo "$post_compact_data" | jq '[.[].reads_in_window] | max // 0')

    # Re-read ratio: post-compaction exploration / total exploration.
    local reread_ratio
    if [[ "$explore_total" -gt 0 ]]; then
        reread_ratio=$(echo "$post_compact_data" | jq --argjson total "$explore_total" \
            '([.[].reads_in_window] | add // 0) / $total * 100 | . * 10 | round / 10')
    else
        reread_ratio="0"
    fi

    jq -n \
        --arg sid "$session_id" \
        --argjson total_tools "$total_tools" \
        --argjson read "$read_count" \
        --argjson glob "$glob_count" \
        --argjson grep "$grep_count" \
        --argjson explore "$explore_total" \
        --argjson compact_count "$compact_count" \
        --argjson total_post_reads "$total_post_reads" \
        --argjson avg_post_reads "$avg_post_reads" \
        --argjson max_post_reads "$max_post_reads" \
        --argjson reread_ratio "$reread_ratio" \
        --argjson per_compaction "$post_compact_data" \
        '{
            session_id: $sid,
            total_tools: $total_tools,
            read: $read, glob: $glob, grep: $grep,
            explore_total: $explore,
            compact_count: $compact_count,
            total_post_reads: $total_post_reads,
            avg_post_reads: $avg_post_reads,
            max_post_reads: $max_post_reads,
            reread_pct: $reread_ratio,
            per_compaction: $per_compaction
        }'
}

# Pretty-print a session report.
print_session() {
    local label="$1" data="$2" window="$3"

    local sid total_tools read glob grep explore compact_count
    local total_post avg_post max_post reread_pct

    sid=$(echo "$data" | jq -r '.session_id')
    total_tools=$(echo "$data" | jq '.total_tools')
    read=$(echo "$data" | jq '.read')
    glob=$(echo "$data" | jq '.glob')
    grep=$(echo "$data" | jq '.grep')
    explore=$(echo "$data" | jq '.explore_total')
    compact_count=$(echo "$data" | jq '.compact_count')
    total_post=$(echo "$data" | jq '.total_post_reads')
    avg_post=$(echo "$data" | jq '.avg_post_reads')
    max_post=$(echo "$data" | jq '.max_post_reads')
    reread_pct=$(echo "$data" | jq '.reread_pct')

    printf "%s: %s\n" "$label" "$sid"
    printf "  Total tool calls:       %d\n" "$total_tools"
    printf "  Read / Glob / Grep:     %d / %d / %d  (exploration: %d)\n" "$read" "$glob" "$grep" "$explore"
    printf "  Compaction events:      %d\n" "$compact_count"

    if [[ "$compact_count" -gt 0 ]]; then
        printf "  Post-compact reads:     %d total, %.1f avg, %d max  (window: %ds)\n" \
            "$total_post" "$avg_post" "$max_post" "$window"
        printf "  Re-read ratio:          %.1f%% of exploration is post-compaction\n" "$reread_pct"

        # Per-compaction breakdown.
        local i=0
        while [[ $i -lt $compact_count ]]; do
            local reads_w read_w glob_w grep_w
            reads_w=$(echo "$data" | jq ".per_compaction[$i].reads_in_window")
            read_w=$(echo "$data" | jq ".per_compaction[$i].read_in_window")
            glob_w=$(echo "$data" | jq ".per_compaction[$i].glob_in_window")
            grep_w=$(echo "$data" | jq ".per_compaction[$i].grep_in_window")
            printf "    Compaction #%d:        %d exploration calls (Read:%d Glob:%d Grep:%d)\n" \
                $((i + 1)) "$reads_w" "$read_w" "$glob_w" "$grep_w"
            i=$((i + 1))
        done
    else
        printf "  (no compaction events — session may have been too short)\n"
    fi
}

# Print comparison between two sessions.
print_comparison() {
    local data_a="$1" data_b="$2"

    delta_line() {
        local label="$1" val_a="$2" val_b="$3"
        local diff=$((val_b - val_a))
        if [[ "$val_b" -eq 0 && "$val_a" -eq 0 ]]; then
            printf "  %-26s  0 (no data)\n" "$label:"
        elif [[ "$val_b" -eq 0 ]]; then
            printf "  %-26s %+d (B had none)\n" "$label:" "$diff"
        else
            local pct=$((diff * 100 / val_b))
            printf "  %-26s A=%d  B=%d  Δ=%+d (%+d%% of B)\n" "$label:" "$val_a" "$val_b" "$diff" "$pct"
        fi
    }

    # Integer extraction helper.
    iv() { echo "$1" | jq "$2"; }

    local explore_a explore_b compact_a compact_b post_a post_b total_a total_b
    explore_a=$(iv "$data_a" '.explore_total')
    explore_b=$(iv "$data_b" '.explore_total')
    compact_a=$(iv "$data_a" '.compact_count')
    compact_b=$(iv "$data_b" '.compact_count')
    post_a=$(iv "$data_a" '.total_post_reads')
    post_b=$(iv "$data_b" '.total_post_reads')
    total_a=$(iv "$data_a" '.total_tools')
    total_b=$(iv "$data_b" '.total_tools')

    echo "=== Comparison ==="
    echo "  A = with CLAUDE.md, B = without CLAUDE.md"
    echo "  Positive Δ = B used more → CLAUDE.md saved work"
    echo ""
    delta_line "Total tool calls" "$total_a" "$total_b"
    delta_line "Exploration calls" "$explore_a" "$explore_b"
    delta_line "Compaction events" "$compact_a" "$compact_b"
    delta_line "Post-compact re-reads" "$post_a" "$post_b"

    echo ""

    # Verdict.
    local reread_a reread_b
    reread_a=$(echo "$data_a" | jq '.reread_pct')
    reread_b=$(echo "$data_b" | jq '.reread_pct')
    printf "  Re-read ratio:           A=%.1f%%  B=%.1f%%\n" "$reread_a" "$reread_b"

    if [[ "$compact_a" -eq 0 && "$compact_b" -eq 0 ]]; then
        echo ""
        echo "  ⚠ Neither session triggered compaction."
        echo "    Try increasing AB_MAX_TURNS or using a more exploration-heavy prompt."
    fi
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

    echo "Fetching PreToolUse events for Session A..."
    local tools_a
    tools_a=$(fetch_events "$session_a" "PreToolUse")

    echo "Fetching PreCompact events for Session A..."
    local compacts_a
    compacts_a=$(fetch_events "$session_a" "PreCompact")

    echo "Fetching PreToolUse events for Session B..."
    local tools_b
    tools_b=$(fetch_events "$session_b" "PreToolUse")

    echo "Fetching PreCompact events for Session B..."
    local compacts_b
    compacts_b=$(fetch_events "$session_b" "PreCompact")

    echo ""

    local data_a data_b
    data_a=$(analyze_session "$session_a" "$tools_a" "$compacts_a" "$COMPACT_WINDOW")
    data_b=$(analyze_session "$session_b" "$tools_b" "$compacts_b" "$COMPACT_WINDOW")

    echo "=== Compaction Impact Analysis ==="
    echo "  Post-compaction window: ${COMPACT_WINDOW}s"
    echo ""
    print_session "Session A (with CLAUDE.md)   " "$data_a" "$COMPACT_WINDOW"
    echo ""
    print_session "Session B (without CLAUDE.md)" "$data_b" "$COMPACT_WINDOW"
    echo ""
    print_comparison "$data_a" "$data_b"
}

main "$@"
