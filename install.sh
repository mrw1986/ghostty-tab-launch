#!/bin/bash
#
# Install ghostty-tab-launch
#
# Installs:
#   1. Fish startup hook → ~/.config/fish/conf.d/ghostty-tab-hook.fish
#   2. Launch script → ~/.local/bin/ghostty-tab-launch

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}Installing ghostty-tab-launch...${NC}"
echo ""

# Check requirements
if ! command -v fish &>/dev/null; then
    echo -e "${YELLOW}Warning: fish shell not found. Install it first: https://fishshell.com${NC}"
fi

if ! command -v gdbus &>/dev/null; then
    echo -e "${YELLOW}Warning: gdbus not found. It's usually included with glib2/GNOME.${NC}"
fi

if ! command -v ghostty &>/dev/null; then
    echo -e "${YELLOW}Warning: ghostty not found. Install it first: https://ghostty.org${NC}"
fi

# 1. Install fish hook
FISH_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
mkdir -p "$FISH_CONF_DIR"

cp "$SCRIPT_DIR/ghostty-tab-hook.fish" "$FISH_CONF_DIR/ghostty-tab-hook.fish"
echo -e "  ${GREEN}Installed${NC} fish hook → $FISH_CONF_DIR/ghostty-tab-hook.fish"

# 2. Install launch script
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

cp "$SCRIPT_DIR/ghostty-tab-launch.sh" "$BIN_DIR/ghostty-tab-launch"
chmod +x "$BIN_DIR/ghostty-tab-launch"
echo -e "  ${GREEN}Installed${NC} launcher  → $BIN_DIR/ghostty-tab-launch"

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "Make sure ~/.local/bin is in your PATH, then use:"
echo "  ghostty-tab-launch -- htop"
echo "  ghostty-tab-launch -d ~/Projects/myapp -- npm run dev"
echo "  ghostty-tab-launch -e \"echo hello\""
echo ""
echo "New Ghostty tabs must be opened AFTER installation for the hook to work."
echo "Existing tabs won't pick up the hook until restarted."
