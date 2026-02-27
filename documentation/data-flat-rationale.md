# data_flat Field Rationale

## Why both `data` and `data_flat` exist

MeiliSearch does not perform full-text search inside nested JSON objects. The
`data` field stores the original event data map (preserving structure for
filtering and display), but its nested contents are invisible to search.

`data_flat` is a **derived string field** containing only the leaf string
values from the data map, concatenated with spaces. MeiliSearch tokenizes this
string and makes all the actual content searchable.

| Field | Type | Purpose |
|-------|------|---------|
| `data` | `map[string]interface{}` (JSON object) | Structured storage, filtering, display |
| `data_flat` | `string` | Full-text search over all event content |

## Encoding layers

When a hook event arrives:

1. **Wire format**: JSON payload from hook-client, unmarshaled into `map[string]interface{}`
2. **Transform**: `extractStringValues(data)` walks the map recursively, collecting only string leaf values into a space-separated string
3. **Index**: MeiliSearch stores `data_flat` as a string and tokenizes it for search
4. **API response**: MeiliSearch returns documents as JSON — `data_flat` is a string inside a JSON object, so its content appears with standard JSON string escaping

The escaped quotes (`\"`) visible in raw API responses (e.g.,
`"data_flat":"Bash ls -la /home/user"`) are **standard JSON encoding** of a
string-within-JSON. MeiliSearch internally stores and tokenizes the raw string
correctly — the escaping is purely a display artifact of JSON-in-JSON
serialization.

## The noise problem (pre-improvement)

The original implementation used `json.Marshal(evt.Data)` to produce
`data_flat`, which serialized the entire data map as a JSON string — keys,
syntax, and all. This caused three concrete problems:

### 1. JSON key noise

Every JSON key (`tool_name`, `session_id`, `transcript_path`, ...) became a
searchable token. Searching for "tool" matched every document because
`"tool_name"` appeared in all data_flat strings.

### 2. Content domain mixing

No field boundaries existed within data_flat. Tool output text, prompt text,
file paths, and session metadata were all concatenated into one undifferentiated
blob, making it impossible to search "within" a specific data field via
data_flat alone.

### 3. Relevance dilution

JSON structural tokens (`{`, `}`, `:`, key names) polluted MeiliSearch's term
frequency calculations, reducing the relevance quality of search results.

## Values-only extraction (current implementation)

`extractStringValues()` recursively walks the data map and collects **only
string leaf values**, skipping all JSON keys, numbers, booleans, and null
values. The result is a space-separated string of actual content.

**Before** (JSON serialization):
```
Input:  {"tool_name":"Bash","tool_input":{"command":"ls -la"}}
Output: {"tool_name":"Bash","tool_input":{"command":"ls -la"}}
Tokens: tool_name Bash tool_input command ls la  ← keys are noise
```

**After** (values-only):
```
Input:  {"tool_name":"Bash","tool_input":{"command":"ls -la"}}
Output: Bash ls -la
Tokens: Bash ls la  ← all meaningful content
```

### Known limitations

1. **JSON-within-strings**: If a string value itself contains JSON (e.g., a
   tool response returning a JSON file's contents), the inner JSON keys will be
   tokenized as content. Acceptable — that JSON *is* the content the user
   interacted with.

2. **Map iteration order**: Go maps iterate in non-deterministic order, so the
   output string's word order may vary between runs. Benign — MeiliSearch's
   full-text search tokenizes without regard to word order.

3. **Content domain mixing persists**: Values from different data fields are
   still concatenated into one string. For targeted search, use the top-level
   extracted fields (`prompt`, `error_message`, `file_path`) or the dedicated
   `hook-prompts` index.

## Existing mitigations

- **Top-level fields**: `session_id`, `tool_name`, `prompt`, `file_path`,
  `error_message`, `cwd`, `project_dir` are extracted to dedicated fields for
  precise filtering and targeted search.
- **Attribute ranking**: MeiliSearch's searchable attributes are ordered with
  specific fields first and `data_flat` last, so matches in structured fields
  rank higher.
- **Prompts index**: The `hook-prompts` index contains only UserPromptSubmit
  events with `prompt` as the primary searchable field, eliminating data_flat
  noise entirely for prompt search.

## Migration

Existing documents can be migrated to the values-only format using:

```bash
./bin/hooks-store --migrate
```

This runs `MigrateDataFlat()` between `MigrateDocuments` and `MigratePrompts`,
reading each document's `data` field and rewriting `data_flat` using
`extractStringValues()`. The migration is idempotent.
