#!/usr/bin/env bash
# Set up an A/B test worktree for measuring CLAUDE.md impact.
# Creates a git worktree of claude-hooks-monitor with all CLAUDE.md files removed.
#
# Usage: ./scripts/setup-ab-test.sh [repo_path]
#   repo_path  Path to claude-hooks-monitor repo (default: ../claude-hooks-monitor)
#
# Cleanup: git -C <repo_path> worktree remove /tmp/claude-ab-test-no-claudemd

set -euo pipefail

REPO="${1:-../claude-hooks-monitor}"
WORKTREE="/tmp/claude-ab-test-no-claudemd"

# ── Validation ───────────────────────────────────────────────────────────────

if [[ ! -d "$REPO/.git" ]]; then
    echo "ERROR: '$REPO' is not a git repository." >&2
    echo "Usage: $0 [path/to/claude-hooks-monitor]" >&2
    exit 1
fi

if [[ -d "$WORKTREE" ]]; then
    echo "Worktree already exists at $WORKTREE"
    echo "To remove it: git -C $REPO worktree remove $WORKTREE"
    exit 1
fi

# ── Create worktree ──────────────────────────────────────────────────────────

echo "Creating worktree from $REPO at $WORKTREE..."
git -C "$REPO" worktree add "$WORKTREE" HEAD --detach

# Remove all CLAUDE.md files from the worktree.
local_count=0
while IFS= read -r -d '' f; do
    rm "$f"
    local_count=$((local_count + 1))
done < <(find "$WORKTREE" -name "CLAUDE.md" -print0)

echo "Removed $local_count CLAUDE.md file(s) from worktree."

# Verify none remain.
remaining=$(find "$WORKTREE" -name "CLAUDE.md" | wc -l)
if [[ "$remaining" -ne 0 ]]; then
    echo "WARNING: $remaining CLAUDE.md file(s) still present!" >&2
fi

# ── Instructions ─────────────────────────────────────────────────────────────

cat <<EOF

=== A/B Test Ready ===

Session A (with CLAUDE.md):
  cd $REPO
  claude  # run your test prompt here

Session B (without CLAUDE.md):
  cd $WORKTREE
  claude  # run the SAME test prompt here

After both sessions complete, run the analysis:
  cd $(dirname "$0")/..
  ./scripts/analyze-batch-scans.sh [session_a_id] [session_b_id]
  # Or with no args to auto-detect the two most recent sessions.

Cleanup:
  git -C $REPO worktree remove $WORKTREE

EOF
