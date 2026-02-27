# cmd/hooks-store — Entry point for the hooks-store binary

All files stable — prefer this summary over reading source files.

## main.go

CLI flags: --port (env: HOOKS_STORE_PORT, default: 9800), --meili-url (env: MEILI_URL), --meili-key (env: MEILI_KEY), --meili-index (env: MEILI_INDEX).

Wiring: connects MeiliSearch → creates ingest.Server → creates eventCh (cap 256) → wires SetOnIngest callback (non-blocking send) → starts HTTP server in goroutine → runs tui.Run() (blocks) → shutdown via sync.Once.

`var version = "dev"` — set by ldflags at build time.

Imports: `ingest`, `store`, `tui`.
