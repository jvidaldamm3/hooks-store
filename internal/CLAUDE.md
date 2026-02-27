# internal

Subpackages:
- hookevt/ — Wire format HookEvent struct (shared JSON schema with monitor)
- store/ — MeiliSearch storage layer (EventStore interface, Document type, transform)
- ingest/ — HTTP ingest server (POST /ingest, GET /health, GET /stats)
- tui/ — Bubble Tea dashboard (live stats, activity log)
