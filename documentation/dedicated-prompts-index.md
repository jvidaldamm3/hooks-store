# Dedicated Prompts Index (`hook-prompts`)

Implements item C from [data-extraction-analysis.md](data-extraction-analysis.md)
("Dedicated prompts index"). A separate MeiliSearch index containing only
UserPromptSubmit events with prompt-specific fields and derived metrics.

## Problem

The main `hook-events` index stores all event types (3,755+ documents). Prompt
search has two friction points:

1. **Noise** — Searching the main index for a keyword like "architecture" matches
   prompts but also tool outputs, file contents, and Bash command output that
   happen to contain the same word. Even with `attributesToSearchOn: ["prompt"]`,
   results are mixed with non-prompt documents that have empty prompt fields.

2. **No prompt-specific dimensions** — There's no way to filter or sort by prompt
   characteristics. "Show me my longest prompts" or "find prompts over 200 bytes"
   is impossible without client-side processing of all events.

## Solution

A dedicated `hook-prompts` index stores only the ~104 UserPromptSubmit events
with a lean, prompt-focused schema. The index is populated two ways:

- **Live dual-write** — When `MeiliStore.Index()` processes a UserPromptSubmit
  document, it writes a `PromptDocument` to the prompts index too. The prompts
  write is fail-soft (logs to stderr, doesn't fail the main write).
- **Migration backfill** — `--migrate` scans the main index and backfills
  all existing UserPromptSubmit events into the prompts index.

### PromptDocument schema

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Same UUID as the main index document (enables cross-index joins) |
| `hook_type` | string | Always "UserPromptSubmit" |
| `timestamp` | string | ISO 8601 UTC timestamp |
| `timestamp_unix` | int64 | Unix epoch seconds |
| `session_id` | string | Claude Code session identifier |
| `prompt` | string | The user's prompt text |
| `prompt_length` | int | Derived: `len(prompt)` in bytes |
| `cwd` | string | Working directory at prompt time |
| `project_dir` | string | Project root (from `_monitor` metadata) |
| `permission_mode` | string | Active permission mode (e.g., "default", "bypassPermissions") |
| `has_claude_md` | bool | Whether a CLAUDE.md was present |

Fields deliberately excluded: `data_flat` (search noise source), `data` map
(raw event blob), `tool_name` (always empty for prompts), token/cost metrics
(not present on UserPromptSubmit events).

### Index settings

| Setting | Values |
|---------|--------|
| Searchable | `prompt`, `session_id` |
| Filterable | `session_id`, `timestamp_unix`, `project_dir`, `permission_mode`, `has_claude_md`, `cwd`, `prompt_length` |
| Sortable | `timestamp_unix`, `prompt_length` |
| Pagination | maxTotalHits: 10000 |
| Faceting | maxValuesPerFacet: 500 |

## What You Can Do With It

### 1. Noise-free prompt search

Search prompts without tool output interference:

```bash
# Main index — "architecture" matches prompts AND tool outputs
curl -s localhost:7700/indexes/hook-events/search \
  -d '{"q":"architecture","limit":5}' | jq '.hits | length'
# Returns many results, most are tool output noise

# Prompts index — only matches actual user prompts
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"architecture","limit":5}' | jq '.hits[].prompt'
# Returns only prompts containing "architecture"
```

No need for `attributesToSearchOn` — the index only contains prompts. Every
result is a genuine user prompt.

### 2. Filter and sort by prompt length

Find your longest/shortest prompts, or prompts within a size range:

```bash
# Longest prompts (sort descending)
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","sort":["prompt_length:desc"],"limit":10}' \
  | jq '.hits[] | {prompt_length, prompt: .prompt[:80]}'

# Shortest prompts (continuations like "yes", "ok", "go ahead")
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","sort":["prompt_length:asc"],"limit":10}' \
  | jq '.hits[] | {prompt_length, prompt}'

# Prompts over 200 bytes (substantial instructions)
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"filter":"prompt_length > 200","sort":["prompt_length:desc"],"limit":20}' \
  | jq '.hits[] | {prompt_length, prompt: .prompt[:100]}'

# Short prompts under 20 bytes (commands and confirmations)
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"filter":"prompt_length < 20","limit":50}' \
  | jq '.hits[].prompt'
```

### 3. Faceted prompt analysis

Aggregate prompts across dimensions without scanning all events:

```bash
# Distribution by project
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","limit":0,"facets":["project_dir"]}' \
  | jq '.facetDistribution.project_dir'

# Distribution by permission mode
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","limit":0,"facets":["permission_mode"]}' \
  | jq '.facetDistribution.permission_mode'

# Sessions with CLAUDE.md vs without
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","limit":0,"facets":["has_claude_md"]}' \
  | jq '.facetDistribution.has_claude_md'

# Multi-facet: permission mode × has_claude_md
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","limit":0,"facets":["permission_mode","has_claude_md"]}' \
  | jq '.facetDistribution'
```

### 4. Session-scoped prompt history

Retrieve the full prompt timeline for a specific session:

```bash
SESSION="your-session-id-here"

# All prompts in a session, chronologically
curl -s localhost:7700/indexes/hook-prompts/search \
  -d "{\"filter\":\"session_id = '$SESSION'\",\"sort\":[\"timestamp_unix:asc\"],\"limit\":100}" \
  | jq '.hits[] | {timestamp, prompt: .prompt[:120], prompt_length}'

# Count prompts per session (via faceting)
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","limit":0,"facets":["session_id"]}' \
  | jq '.facetDistribution.session_id'
```

### 5. Project-scoped prompt search

Search within a specific project's prompts:

```bash
# Search for "refactor" only in prompts from a specific project
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"refactor","filter":"project_dir = '\''/home/user/my-project'\''","limit":10}' \
  | jq '.hits[].prompt'

# All prompts from sessions that had a CLAUDE.md
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","filter":"has_claude_md = true","limit":0}' \
  | jq '.estimatedTotalHits'
```

### 6. Cross-index joins

Since PromptDocuments share the same UUID as their main index counterparts,
you can look up the full event data for any prompt:

```bash
# Find a prompt in the prompts index
PROMPT_ID=$(curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"architecture","limit":1}' | jq -r '.hits[0].id')

# Get the full event data from the main index
curl -s localhost:7700/indexes/hook-events/documents/$PROMPT_ID | jq '.data'
```

### 7. Prompt statistics

Combine MeiliSearch queries for quick statistics:

```bash
# Total prompt count
curl -s localhost:7700/indexes/hook-prompts/stats | jq '.numberOfDocuments'

# Average-ish prompt length (get all, compute client-side)
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","limit":200,"attributesToRetrieve":["prompt_length"]}' \
  | jq '[.hits[].prompt_length] | (add / length | floor)'

# Prompts by working directory (where is Claude being used?)
curl -s localhost:7700/indexes/hook-prompts/search \
  -d '{"q":"","limit":0,"facets":["cwd"]}' \
  | jq '.facetDistribution.cwd'
```

## Configuration

### Enable (default)

The prompts index is enabled by default with the name `hook-prompts`:

```bash
./bin/hooks-store                          # prompts index = "hook-prompts"
./bin/hooks-store --prompts-index=my-idx   # custom name
PROMPTS_INDEX=my-idx ./bin/hooks-store     # via environment
```

### Disable

Pass an empty string to skip all prompts index logic:

```bash
./bin/hooks-store --prompts-index=""
```

When disabled, `NewMeiliStore` skips prompts index creation, `Index()` skips
the dual-write, and `MigratePrompts()` returns `(0, nil)` immediately.

### Migration

Backfill existing UserPromptSubmit events into the prompts index:

```bash
./bin/hooks-store --migrate
# Output:
# Connecting to MeiliSearch at http://localhost:7700...
# Starting migration...
# Migrated 100/3755 documents
# ...
# Migration complete: 3755 documents processed
# Migrating prompts index...
# Prompts: migrated 12 so far (scanned 100/3755)
# Prompts: migrated 25 so far (scanned 200/3755)
# ...
# Prompts migration complete: 104 documents processed
```

The prompts migration scans the main index and filters UserPromptSubmit events
client-side (MeiliSearch's `GetDocuments` API doesn't support server-side
filtering). It must run after `MigrateDocuments` so that top-level fields
(`prompt`, `project_dir`, etc.) are already backfilled.

## Design Decisions

### Why a separate index instead of filtered searches?

MeiliSearch can restrict search to specific attributes
(`attributesToSearchOn: ["prompt"]`), but the results still include all document
types — you get PreToolUse and PostToolUse documents with empty prompt fields
ranked alongside actual prompts. A dedicated index guarantees every result is a
prompt. It also enables prompt-specific fields (`prompt_length`) and
prompt-focused faceting without polluting the main index schema.

### Why fail-soft dual-write?

The prompts index is a secondary, derived view. If the write fails (e.g.,
MeiliSearch temporarily overloaded), the event is still safely stored in the
main index. The next `--migrate` run can backfill any missed entries. Failing
the main `Index()` call over a prompts write failure would be
disproportionate.

### Why byte count for prompt_length?

`len(prompt)` in Go returns byte count, not character/rune count. For
ASCII-dominant English prompts, bytes closely track characters. Byte count is
O(1) (Go string headers carry length) while rune counting is O(n). For
filtering and sorting purposes — "find long prompts", "sort by length" — the
exact count doesn't matter; relative ordering is preserved regardless of
encoding.

### Why same document ID?

Reusing the UUID from the main index enables cross-index joins. Given a prompt
found in `hook-prompts`, you can directly fetch its full event data (including
the raw `data` map with all Claude Code context) from `hook-events` using the
same ID.

## Files

| File | Role |
|------|------|
| `internal/store/store.go` | `PromptDocument` struct definition |
| `internal/store/transform.go` | `DocumentToPromptDocument()` conversion |
| `internal/store/transform_test.go` | Tests for prompt document conversion |
| `internal/store/meili.go` | `setupPromptsIndex()`, dual-write in `Index()`, `MigratePrompts()`, `extractPromptMigrationFields()` |
| `cmd/hooks-store/main.go` | `--prompts-index` flag, migration wiring |

## Relationship to Previous Work

- **Item A** (top-level field extraction) and **Item B** (index settings update)
  from [data-extraction-analysis.md](data-extraction-analysis.md) were implemented
  in [top-level-field-extraction.md](top-level-field-extraction.md).
- **Item C** (dedicated prompts index) is this implementation.
- The prompts index builds on items A and B — it reads the backfilled top-level
  fields rather than re-parsing the nested `data` map.
