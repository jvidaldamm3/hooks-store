# Data Extraction & Analysis — Hook Traces in MeiliSearch

Findings from analyzing the hook-events index (Feb 25–27, 2026).
Covers what data exists, what can be extracted, and indexing improvements.

## Database Overview

**3,755 events** across **34 sessions**, **104 user prompts**.

| Hook Type | Count | Key Fields |
|-----------|-------|------------|
| UserPromptSubmit | 104 | `prompt`, `cwd`, `permission_mode` |
| PreToolUse | 1,614 | `tool_name`, `tool_input` (file paths, code, commands) |
| PostToolUse | 1,548 | `tool_name`, `tool_input`, `tool_response` (full output) |
| PostToolUseFailure | 51 | `tool_name`, `tool_input`, `error`, `is_interrupt` |
| Stop | 96 | `last_assistant_message`, `stop_hook_active` |
| Notification | 46 | `message`, `notification_type` |
| SessionStart | 56 | `source` |
| SessionEnd | 49 | `reason` |
| PreCompact | 5 | `trigger`, `custom_instructions` |
| SubagentStart | 23 | `agent_id`, `agent_type` |
| SubagentStop | 83 | `agent_id`, `agent_type`, `last_assistant_message` |

All events carry: `session_id`, `cwd`, `_monitor.project_dir`, `_monitor.has_claude_md`, `transcript_path`.

## Current Index Configuration

### What's configured (running MeiliSearch)

| Setting | Values |
|---------|--------|
| Filterable | `hook_type`, `session_id`, `tool_name`, `timestamp_unix` |
| Sortable | `timestamp_unix` |
| Searchable | `hook_type`, `tool_name`, `session_id`, `data_flat` |
| Pagination maxTotalHits | 1000 |
| Faceting maxValuesPerFacet | 100 |

### Known issues

1. **Settings are stale** — The code (`meili.go`) configures `has_claude_md` and `cost_usd` as filterable, but the running index was created before those fields were added. Settings need a manual update or index recreation.
2. **Token/cost data is empty** — The Document struct has fields for `input_tokens`, `output_tokens`, `cost_usd`, but Claude Code hook events don't emit this data. The Stop hook gives `last_assistant_message` but no usage stats.
3. **Full-text search is blunt** — Searching `data_flat` for "architecture" matches prompts but also tool inputs/outputs containing that word. No way to search only prompt text.

## Extractable Data — 7 Analysis Categories

### 1. Prompt Analysis

Extract all `UserPromptSubmit` events, pull `data.prompt`. Enables:

- **Classify prompts**: commands ("commit this"), questions ("how to..."), instructions ("implement X"), continuations ("yes", "ok")
- **Measure prompt complexity** by length and specificity
- **Track prompt patterns** per session — how sessions evolve
- **Search prompts** by keyword (works via `data_flat`, but noisy)

### 2. Session Timelines

Reconstruct full session flows:

```
SessionStart → [UserPromptSubmit → PreToolUse* → PostToolUse* → Stop*]* → SessionEnd
```

Gives:
- Work-per-prompt (tool calls triggered by each prompt)
- Session duration and phases
- Detection of "stuck" moments (many tool calls between prompts)

### 3. Tool Usage Patterns

From PreToolUse events:
- Which tools are used most, per session, per project
- **File access patterns** from Read events — most-read files, re-reads
- Tool call diversity (Read-only sessions vs mixed Read/Edit/Bash)

### 4. Error Analysis

51 PostToolUseFailure events available. Analysis targets:
- Which tools fail most and why
- Sandbox restriction failures vs missing files vs bad commands
- Interrupted vs completed failures (`is_interrupt` field)

### 5. Exploration Efficiency

Ratio of "productive" tools (Edit, Write, Bash) vs "exploration" tools (Read, Glob, Grep):
- Higher exploration ratio = more wasted tokens
- Compare across sessions with/without CLAUDE.md (using `has_claude_md`)

### 6. Subagent Behavior

23 SubagentStart, 83 SubagentStop events:
- What agent types are spawned
- What they accomplish (`last_assistant_message`)
- Ratio of subagent work vs direct work

### 7. Post-Compaction Recovery

5 PreCompact events across 3 sessions:
- What tools are used in the burst after compaction
- Whether CLAUDE.md reduces the recovery cost (validated in experiments — see below)

## Experiment Results (Feb 26, 2026)

Three A/B experiments were run to measure CLAUDE.md impact. Key session pairs:

### Experiment 1: CLAUDE.md Impact on Exploration

Prompt: "Explain the architecture"

| Metric | WITH CLAUDE.md | WITHOUT | Delta |
|--------|---------------|---------|-------|
| Pair 1 tool calls | 16 | 44 | **-64%** |
| Pair 2 tool calls | 16 | 36 | **-56%** |
| Avg Read calls | 14 | 21 | -33% |
| Avg Bash calls | 0 | 14 | eliminated |
| Avg total events | 40 | 86 | **-53%** |

Without CLAUDE.md, Claude resorts to Bash exploration (13-15 calls), Grep, and Task spawning. With CLAUDE.md, it goes straight to targeted Reads.

### Experiment 2: File Cache Feature

| Session | Condition | Tool Calls |
|---------|-----------|------------|
| 9aa4e1a0 | WITH cache | 6 |
| 78220749 | WITHOUT cache | 4 |
| 87cce9fa | WITH cache | 13 |
| da76b006 | WITHOUT cache | 6 |

**Inconclusive.** Sessions too short (4-13 calls). The file cache annotates events but doesn't directly reduce calls.

### Experiment 3: Post-Compaction Re-read Penalty

Pair with compaction (2 compaction events each):

| Metric | WITH CLAUDE.md | WITHOUT |
|--------|---------------|---------|
| Total tool calls | 50 | 48 |
| Before compaction | 30 | 28 |
| **60s burst after compaction** | **2** | **6** |
| After compaction (all) | 20 | 20 |

Post-compaction burst is **3x larger without CLAUDE.md**. Without it, Claude needs Glob calls to rediscover file structure. With it, Claude goes directly to Read.

### Session IDs Reference

| Experiment | WITH CLAUDE.md | WITHOUT |
|------------|---------------|---------|
| Batch scan pair 1 | 3a38cd61 | 150f0b1c |
| Batch scan pair 2 | 5e2a2502 | 35cb6e2c |
| File cache pair 1 | 9aa4e1a0 | 78220749 |
| File cache pair 2 | 87cce9fa | da76b006 |
| Compaction pair 1 | 677e4783 | aaa18cef |
| Compaction pair 2 | f1f87bfb | 70b4739e |

## Indexing Improvements

### A. New top-level fields in `transform.go`

| Field | Source | Purpose |
|-------|--------|---------|
| `prompt` | `data.prompt` (UserPromptSubmit) | Search/filter prompts without tool output noise |
| `file_path` | `data.tool_input.file_path` (Read/Edit/Write) | Filter/facet by file access |
| `error_message` | `data.error` (PostToolUseFailure) | Search errors directly |
| `project_dir` | `data._monitor.project_dir` | Filter by project |
| `cwd` | `data.cwd` | Filter by working directory |
| `permission_mode` | `data.permission_mode` | Filter by permission mode |

### B. MeiliSearch index settings update

| Setting | Add |
|---------|-----|
| Filterable | `has_claude_md`, `project_dir`, `permission_mode`, `file_path` |
| Sortable | `input_tokens`, `output_tokens`, `cost_usd` (for future token data) |
| Searchable | `prompt` (high priority, before `data_flat`) |
| Pagination | Raise `maxTotalHits` from 1000 to 10000 |
| Faceting | Raise `maxValuesPerFacet` from 100 to 500 |

### C. Dedicated prompts index (optional)

A separate `hook-prompts` index storing only UserPromptSubmit events with `prompt` as primary searchable field. Eliminates noise from tool data. Could also store derived fields like prompt length, prompt category.

## Recommended Implementation Order

1. **Prompt extraction script** — Pull all prompts, output clean JSON/markdown for LLM analysis (no code changes needed)
2. **Index settings update** — Apply filterable/sortable/pagination changes to running index (live, no data loss)
3. **`transform.go` field extraction** — Add `prompt`, `file_path`, `project_dir` as top-level Document fields
4. **Re-index existing data** — Backfill new fields by re-ingesting historical events
5. **Dedicated prompts index** — If prompt analysis becomes a primary workflow
