#!/usr/bin/env bash
# Install MeiliSearch for hooks-store companion.
# Usage: ./scripts/install-meili.sh [--service]
#
# Options:
#   (no args)   Download binary to ~/.local/bin
#   --service   Also install as user systemd service

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
DATA_DIR="${DATA_DIR:-$HOME/.local/share/meilisearch}"
PORT="${MEILI_PORT:-7700}"

# 1. Download binary via official installer
mkdir -p "$INSTALL_DIR" "$DATA_DIR"

echo "Downloading MeiliSearch..."
dl_dir=$(mktemp -d)
trap 'rm -rf "$dl_dir"' EXIT
cd "$dl_dir"
curl -fsSL https://install.meilisearch.com | sh

mv ./meilisearch "$INSTALL_DIR/meilisearch"
chmod +x "$INSTALL_DIR/meilisearch"
cd - >/dev/null

# 2. Verify installation
echo ""
"$INSTALL_DIR/meilisearch" --version
echo "Installed to: $INSTALL_DIR/meilisearch"
echo "Data directory: $DATA_DIR"

# 3. Ensure ~/.local/bin is in PATH
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    echo ""
    echo "WARNING: $INSTALL_DIR is not in your PATH."
    echo "Add this to your shell profile:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

# 4. Optional: install as user systemd service
if [[ "${1:-}" == "--service" ]]; then
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/meilisearch.service << UNIT
[Unit]
Description=MeiliSearch search engine
After=network.target

[Service]
ExecStart="$INSTALL_DIR/meilisearch" --db-path "$DATA_DIR/data.ms" --http-addr 127.0.0.1:$PORT
Restart=on-failure
RestartSec=5
Environment=MEILI_NO_ANALYTICS=true

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now meilisearch
    echo ""
    echo "MeiliSearch installed as user systemd service (port $PORT)"
    echo "  Status:  systemctl --user status meilisearch"
    echo "  Logs:    journalctl --user -u meilisearch -f"
    echo "  Stop:    systemctl --user stop meilisearch"
else
    echo ""
    echo "To run manually:"
    echo "  meilisearch --db-path $DATA_DIR/data.ms --http-addr 127.0.0.1:$PORT"
    echo ""
    echo "To install as a service:"
    echo "  $0 --service"
fi
