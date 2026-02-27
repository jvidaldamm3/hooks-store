# Top-Level Field Extraction — Precise Search and Filtering

## Problem

Hook event data arrives as a flat JSON blob stored in the `data` map on each
Document. Key fields — the user's prompt text, file paths being accessed, error
messages, project directories — are buried inside this nested structure. The only
way to search them was through `data_flat`, a serialized JSON string that
MeiliSearch indexes for full-text search.

This created three concrete problems:

### 1. Search noise

Searching `data_flat` for "architecture" matches:

- A user prompt: `"explain the architecture"` (what you wanted)
- A tool response containing the word "architecture" in file contents (noise)
- A Bash command that happened to print "architecture" in output (noise)

There was no way to restrict search to *only prompts* or *only errors*. Every
search query hit the entire serialized data blob of every event.

### 2. Inability to filter

MeiliSearch can only filter on top-level document fields that are declared
filterable. You could filter by `hook_type` or `tool_name` (already extracted),
but not by:

- Which project directory an event came from
- Which file was being read/written
- What permission mode was active

These values existed in every document's `data` map but were invisible to
MeiliSearch's filter engine.

### 3. No faceting on key dimensions

Faceted search (e.g., "show me the distribution of events by project directory")
requires filterable attributes. Without top-level `project_dir`, you couldn't
answer "how many events came from each project?" without scanning all documents
client-side.

## Solution: Extract, Don't Duplicate

Six fields are now extracted from the `data` map and stored as top-level
Document fields during ingestion:

| Field | Source Path | Hook Types | Purpose |
|-------|------------|------------|---------|
| `prompt` | `data.prompt` | UserPromptSubmit | Search user prompts without tool output noise |
| `file_path` | `data.tool_input.file_path` | PreToolUse (Read, Edit, Write, Glob) | Filter/facet by accessed files |
| `error_message` | `data.error` | PostToolUseFailure | Search errors directly |
| `project_dir` | `data._monitor.project_dir` | All (injected by hook-client) | Filter/facet by project |
| `permission_mode` | `data.permission_mode` | UserPromptSubmit | Filter by permission level |
| `cwd` | `data.cwd` | All | Filter/facet by working directory |

### Why these six?

The first five were identified during the [data extraction analysis](data-extraction-analysis.md)
(section "Indexing Improvements") as the highest-value fields based on two
criteria:

1. **Query frequency** — Project filtering, prompt search, and error search are
   the most common analytical queries against the hook event database.
2. **Noise reduction** — `prompt` and `error_message` are the fields most
   polluted by `data_flat` search because tool output text frequently contains
   the same keywords.

`cwd` was added later as the sixth extracted field — unlike `project_dir` (stable
per session), `cwd` varies within a session when Claude works in submodules,
nested directories, or worktrees, making it valuable for directory-level analysis.

### Why not extract everything?

Only fields with clear filtering or search value are promoted. Fields like
`tool_response`, `last_assistant_message` remain accessible via `data_flat`
(full-text) and the raw `data` map (structured access). Extracting rarely-queried
fields would bloat the Document schema and the MeiliSearch index without
meaningful benefit.

## Architectural Decisions

### `omitempty` on all new fields

Each field only applies to specific hook types. A `PreToolUse Read` event has
`file_path` but no `prompt`. A `UserPromptSubmit` has `prompt` but no
`file_path`. Using `omitempty` means absent fields are excluded from the JSON
payload entirely:

```json
// UserPromptSubmit — only prompt is set
{"id": "abc", "hook_type": "UserPromptSubmit", "prompt": "explain the architecture", ...}

// PreToolUse Read — only file_path is set
{"id": "def", "hook_type": "PreToolUse", "file_path": "/src/main.go", ...}
```

Without `omitempty`, every document would carry five empty string fields, wasting
storage and polluting MeiliSearch's filter/facet results with empty values.

### Searchable attribute ordering

MeiliSearch's `attributeRank` ranking rule (configured on this index) assigns
higher relevance to attributes listed earlier in the searchable attributes list.
The new ordering is:

```
hook_type, tool_name, session_id, prompt, error_message, data_flat
```

`prompt` and `error_message` are placed *before* `data_flat`. This means
searching for "architecture" will rank a document where the *prompt* contains
"architecture" higher than one where the word appears somewhere in the tool
output blob. `data_flat` remains as a catch-all fallback at the end.

### Filterable attributes for new dimensions

Three new filterable attributes enable queries that were previously impossible:

```
project_dir     → filter="project_dir = '/home/user/myproject'"
permission_mode → filter="permission_mode = 'bypassPermissions'"
file_path       → filter="file_path EXISTS"
```

The `EXISTS` filter is particularly useful for `file_path` — it returns all
events that accessed a file, regardless of which file. Combined with faceting,
this enables file access pattern analysis.

### Settings task synchronization

Previously, `NewMeiliStore` fired settings update requests as async MeiliSearch
tasks and returned immediately. Settings were *eventually* applied but there was
no guarantee they were active when the first document was indexed.

This was acceptable when the server ran continuously (settings applied within
seconds), but the new `--migrate` flag requires settings to be in place *before*
document updates begin — specifically, the new filterable attributes must be
indexed before partial updates reference them.

`NewMeiliStore` now calls `WaitForTask` after each settings update. The polling
interval is 500ms. Settings tasks typically complete in under a second, so this
adds negligible startup time (~1–2s total) while guaranteeing correctness.

## Migration Strategy

### The problem with historical data

3,755 existing documents in MeiliSearch have the new fields buried in their
`data` maps but lack top-level `prompt`, `file_path`, etc. New events ingested
after the code change get all fields automatically, but historical data would
remain unsearchable by the new fields without a backfill.

### Approach: Partial document merge

MeiliSearch's `UpdateDocuments` (HTTP PUT to `/documents`) performs a **partial
merge** — it only modifies fields present in the update payload. Sending:

```json
{"id": "existing-uuid", "prompt": "explain the architecture"}
```

adds the `prompt` field to the document without touching `data`, `data_flat`,
`hook_type`, or any other existing field. This is fundamentally different from
`AddDocuments` (HTTP POST), which would **replace** the entire document.

### Algorithm

```
for each page of 100 documents:
    fetch documents with fields: [id, data]
    for each document:
        unmarshal data map from json.RawMessage
        extract fields using same logic as transform.go
        if any new field was extracted:
            add to batch update list
    if batch is non-empty:
        UpdateDocuments(batch)    ← HTTP PUT, partial merge
        WaitForTask(taskUID)      ← block until indexed
    print progress
```

### Safety properties

| Property | Mechanism |
|----------|-----------|
| No data loss | `UpdateDocuments` (PUT) merges fields; never removes existing ones |
| Idempotent | Running migration twice applies same values — no side effects |
| Resumable | Progress is per-page; a failed run can be restarted safely |
| Context-aware | Respects `context.Context` cancellation for clean SIGINT shutdown |
| Sequential consistency | `WaitForTask` after each batch ensures no race conditions |
| Skip-on-empty | Documents with no extractable fields are skipped (`len(partial) > 1` check) |

### Why not re-ingest from scratch?

Re-ingesting would require access to the original hook event payloads (which
are not stored outside MeiliSearch). The migration reads from MeiliSearch itself
— the `data` map on each document contains the complete original event data,
which is sufficient to extract the new fields.

### Concurrent operation

The migration is safe to run while the server is ingesting new events:

- New events get all fields via `HookEventToDocument` in `transform.go`
- Old events get backfilled by the migration
- If a document is updated by both (race), the result is identical because
  both extract the same fields from the same `data` map

## Usage

```bash
# Build
cd hooks-store && make build

# Run migration (MeiliSearch must be running)
./bin/hooks-store --migrate

# Expected output:
# Connecting to MeiliSearch at http://localhost:7700...
# Starting migration...
# Migrated 100/3755 documents
# Migrated 200/3755 documents
# ...
# Migration complete: 3755 documents processed

# Verify — prompt search now returns only prompt matches
curl -s localhost:7700/indexes/hook-events/search \
  -d '{"q":"architecture","attributesToSearchOn":["prompt"],"limit":3}' \
  | jq '.hits[].prompt'

# Verify — project_dir faceting works
curl -s localhost:7700/indexes/hook-events/search \
  -d '{"limit":0,"facets":["project_dir"]}' \
  | jq '.facetDistribution.project_dir'

# Verify — file_path filtering works
curl -s localhost:7700/indexes/hook-events/search \
  -d '{"filter":"file_path EXISTS","limit":0}' \
  | jq '.estimatedTotalHits'
```

## Files Modified

| File | Change |
|------|--------|
| `internal/store/store.go` | Added 6 fields to `Document` struct |
| `internal/store/transform.go` | Field extraction in `HookEventToDocument` |
| `internal/store/transform_test.go` | 7 new tests for extraction (present + absent cases) |
| `internal/store/meili.go` | Updated index settings; `WaitForTask` synchronization; `MigrateDocuments` method |
| `cmd/hooks-store/main.go` | `--migrate` CLI flag |

## Relationship to Previous Work

This implements items A and B from the "Indexing Improvements" section of
[data-extraction-analysis.md](data-extraction-analysis.md), which identified
these fields and the search noise problem. Item C (dedicated prompts index) has
been implemented as the `hook-prompts` index — a lean, dedicated MeiliSearch
index containing only UserPromptSubmit events with prompt-specific fields
(`prompt_length` for filtering/sorting). See `internal/store/meili.go` for the
`setupPromptsIndex()` and `MigratePrompts()` implementation.
