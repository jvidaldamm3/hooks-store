package hookevt

import "time"

// HookEvent matches the JSON wire format sent by the Claude Hooks Monitor.
// This is an independent definition — no imports from the monitor module.
// The contract between the two programs is the JSON schema, not Go types.
type HookEvent struct {
	HookType  string                 `json:"hook_type"`
	Timestamp time.Time              `json:"timestamp"`
	Data      map[string]interface{} `json:"data"`
}
