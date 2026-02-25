#!/usr/bin/env bash
# Configure MeiliSearch index for hook events.
# Run once after MeiliSearch is installed and running.
#
# Usage: ./scripts/setup-meili-index.sh
# Environment:
#   MEILI_URL   MeiliSearch endpoint (default: http://localhost:7700)
#   MEILI_KEY   MeiliSearch API key (default: none)

set -euo pipefail

MEILI_URL="${MEILI_URL:-http://localhost:7700}"
MEILI_KEY="${MEILI_KEY:-}"
INDEX="hook-events"

# Build auth header if API key is set.
AUTH_HEADER=""
if [[ -n "$MEILI_KEY" ]]; then
    AUTH_HEADER="Authorization: Bearer $MEILI_KEY"
fi

curl_meili() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-s --fail-with-body -X "$method" "$MEILI_URL$path" -H 'Content-Type: application/json')
    if [[ -n "$AUTH_HEADER" ]]; then
        args+=(-H "$AUTH_HEADER")
    fi
    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi
    local response http_code
    response=$(curl -w "\n%{http_code}" "${args[@]}" 2>&1)
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        return 0
    elif [[ "$http_code" == "409" ]]; then
        # Index already exists — not an error.
        return 0
    else
        echo "FAILED (HTTP $http_code)"
        echo "  $body" >&2
        return 1
    fi
}

# Check MeiliSearch is reachable.
echo "Checking MeiliSearch at $MEILI_URL..."
if ! curl -sf "$MEILI_URL/health" >/dev/null 2>&1; then
    echo "ERROR: MeiliSearch is not reachable at $MEILI_URL"
    echo "Start it first: meilisearch --db-path ~/.local/share/meilisearch/data.ms"
    exit 1
fi
echo "MeiliSearch is healthy."

echo ""
echo "Configuring index '$INDEX'..."

# Create index with primary key.
echo -n "  Creating index... "
if curl_meili POST "/indexes" "{\"uid\":\"$INDEX\",\"primaryKey\":\"id\"}"; then
    echo "ok"
else
    echo "failed" >&2; exit 1
fi

# Searchable attributes (full-text search targets).
echo -n "  Setting searchable attributes... "
if curl_meili PUT "/indexes/$INDEX/settings/searchable-attributes" \
    '["hook_type","tool_name","session_id","data_flat"]'; then
    echo "ok"
else
    echo "failed" >&2; exit 1
fi

# Filterable attributes (for faceted queries).
echo -n "  Setting filterable attributes... "
if curl_meili PUT "/indexes/$INDEX/settings/filterable-attributes" \
    '["hook_type","session_id","tool_name","timestamp_unix"]'; then
    echo "ok"
else
    echo "failed" >&2; exit 1
fi

# Sortable attributes (chronological ordering).
echo -n "  Setting sortable attributes... "
if curl_meili PUT "/indexes/$INDEX/settings/sortable-attributes" \
    '["timestamp_unix"]'; then
    echo "ok"
else
    echo "failed" >&2; exit 1
fi

echo ""
echo "Index '$INDEX' configured successfully."
echo "Dashboard: $MEILI_URL"
