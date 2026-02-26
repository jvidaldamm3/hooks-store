# scripts

MeiliSearch setup and analysis scripts.

## Files
- install-meili.sh: Downloads and installs MeiliSearch binary to ~/.local/bin, optional --service flag for systemd
- setup-meili-index.sh: Configures MeiliSearch index with searchable/filterable/sortable attributes (run once)
- analyze-batch-scans.sh: Queries MeiliSearch to compare tool usage between two sessions, detects batch scans (3+ consecutive Read/Glob/Grep), produces CLAUDE.md impact report. Args: [session_a] [session_b] or auto-detects two most recent sessions.
- setup-ab-test.sh: Creates a git worktree of claude-hooks-monitor with all CLAUDE.md files removed for A/B testing. Args: [repo_path] (default: ../claude-hooks-monitor).
- run-ab-test.sh: End-to-end A/B test runner. Creates worktree, runs two Claude sessions (with/without CLAUDE.md), identifies session IDs, runs analysis, cleans up. Must run outside Claude Code. Env: MEILI_URL, AB_PROMPT, AB_MAX_TURNS.
- run-compaction-experiment.sh: Like run-ab-test.sh but designed to trigger context compaction. Uses higher max-turns (50) and a deep multi-step prompt to fill the context window. Runs compaction analysis + batch-scan analysis. Env: MEILI_URL, AB_PROMPT, AB_MAX_TURNS, COMPACT_WINDOW.
- analyze-compaction.sh: Queries MeiliSearch for PreCompact and PreToolUse events, measures post-compaction "re-read penalty" (exploration calls in a time window after each compaction). Compares two sessions. Args: [session_a] [session_b] or auto-detects. Env: MEILI_URL, COMPACT_WINDOW (default: 120s).
- run-full-experiment.sh: Complete experiment runner. Runs two sessions, gathers all event data, computes metrics, generates an unbiased markdown report with tables and auto-derived observations. Saves raw events JSON, computed summaries, and comparison data. Output: $REPORT_DIR/report.md + raw/ + data/. Env: MEILI_URL, AB_PROMPT, AB_MAX_TURNS, COMPACT_WINDOW, REPORT_DIR.
