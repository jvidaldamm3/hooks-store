# hookevt — Wire format for hook events from Claude Code

All files stable — prefer this summary over reading source files.

## hookevt.go

```go
type HookEvent struct {
    HookType  string                 `json:"hook_type"`
    Timestamp time.Time              `json:"timestamp"`
    Data      map[string]interface{} `json:"data"`
}
```

Independent definition — no imports from the monitor module. The contract between programs is the JSON schema, not Go types.

No concurrency primitives. No internal imports.
