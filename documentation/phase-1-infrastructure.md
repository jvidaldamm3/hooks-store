# Phase 1: MeiliSearch Infrastructure + Scaffolding

## Overview

This phase establishes the foundation: MeiliSearch installation, index configuration,
and the `hooks-store` Go module skeleton.

## MeiliSearch Setup

### Installation

MeiliSearch is installed as a user-local binary (no root required):

```
~/.local/bin/meilisearch       ← binary
~/.local/share/meilisearch/    ← data directory
```

Two modes:
- **Manual**: `meilisearch --db-path ~/.local/share/meilisearch/data.ms`
- **Service**: user systemd unit at `~/.config/systemd/user/meilisearch.service`

The binary binds to `127.0.0.1:7700` — localhost only, no external exposure.

### Index Schema

The `hook-events` index stores flattened hook event documents:

| Attribute | Type | Purpose |
|-----------|------|---------|
| `id` | string (UUID v4) | Primary key — unique per event |
| `hook_type` | string | Event type (e.g., "PreToolUse") — searchable + filterable |
| `timestamp` | string (RFC3339) | Human-readable timestamp |
| `timestamp_unix` | int64 | Unix epoch — sortable for chronological queries |
| `session_id` | string | Claude session ID — filterable |
| `tool_name` | string | Tool name (e.g., "Write", "Bash") — searchable + filterable |
| `data_flat` | string | JSON-serialized event data — full-text searchable |
| `data` | object | Original event data preserved as-is |

**Rationale for `data_flat`**: MeiliSearch does full-text search on string fields.
The original `data` is a nested JSON object whose inner fields wouldn't be searched.
`data_flat` serializes the entire data map to a string, making all nested content
(file paths, command output, prompts) searchable.

### MeiliSearch index settings

```
Searchable:  ["hook_type", "tool_name", "session_id", "data_flat"]
Filterable:  ["hook_type", "session_id", "tool_name", "timestamp_unix"]
Sortable:    ["timestamp_unix"]
Primary key: "id"
```

## Module Structure

```
hooks-store/
├── cmd/hooks-store/main.go        ← entry point (stub for now)
├── internal/
│   ├── hookevt/hookevt.go         ← HookEvent struct (JSON wire format)
│   ├── ingest/                    ← HTTP server (Phase 4)
│   └── store/                     ← EventStore + MeiliStore (Phase 3)
├── scripts/
│   ├── install-meili.sh           ← MeiliSearch installation
│   └── setup-meili-index.sh       ← Index configuration
├── documentation/                 ← Phase docs (you are here)
├── go.mod                         ← module: hooks-store
└── Makefile
```

The module is **fully independent** from `claude-hooks-monitor`. The two programs
share a JSON wire format, not Go imports. `internal/hookevt/hookevt.go` defines
its own `HookEvent` struct matching the monitor's JSON output.

## How to Run

```bash
# Install MeiliSearch
make install-meili

# Start MeiliSearch (manual)
meilisearch --db-path ~/.local/share/meilisearch/data.ms

# Or start as service
make install-meili-service

# Configure the index (run once)
make setup-meili-index

# Verify
make meili-health
```

## Useful Commands

```bash
make meili-search Q="Write"     # Search for events containing "Write"
make meili-stats                 # Show index statistics
make meili-health                # Check MeiliSearch is running
```
