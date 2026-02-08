#!/bin/bash
#
# Uninstall ghostty-tab-launch

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Uninstalling ghostty-tab-launch...${NC}"

FISH_HOOK="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/ghostty-tab-hook.fish"
LAUNCHER="$HOME/.local/bin/ghostty-tab-launch"

[ -f "$FISH_HOOK" ] && rm -f "$FISH_HOOK" && echo -e "  ${GREEN}Removed${NC} $FISH_HOOK"
[ -f "$LAUNCHER" ] && rm -f "$LAUNCHER" && echo -e "  ${GREEN}Removed${NC} $LAUNCHER"

# Clean up any leftover temp files
rm -f /tmp/ghostty-tab-pending.fish /tmp/ghostty-tab-claimed-*.fish /tmp/ghostty-tab-launch-*.fish 2>/dev/null

echo -e "${GREEN}Done!${NC}"
