#!/bin/bash
#
# ghostty-tab-launch — Open a new Ghostty tab with a specific command
#
# Workaround for Ghostty's lack of programmatic tab creation with commands.
# Ghostty's DBus `new-tab` action doesn't accept a command parameter, so this
# tool uses a fish shell startup hook to bridge the gap.
#
# Tracks: https://github.com/ghostty-org/ghostty/discussions/2353
#
# Usage:
#   ghostty-tab-launch [options] [--] <command> [args...]
#   ghostty-tab-launch -e <command> [args...]
#
# Options:
#   -e <command>     Command to run in the new tab (alternative to positional args)
#   -d <dir>         Working directory for the new tab (default: current directory)
#   -w <N>           Target Ghostty window number (default: auto-detect)
#   -t <title>       Display a title line before running the command
#   -s <file>        Run a fish script file instead of a command string
#   -f               Force new window fallback (skip DBus tab attempt)
#   -h               Show this help message
#
# Examples:
#   ghostty-tab-launch -- htop
#   ghostty-tab-launch -d ~/Projects/myapp -- npm run dev
#   ghostty-tab-launch -e "claude --dangerously-skip-permissions 'Hello'"
#   ghostty-tab-launch -t "Dev Server" -d ~/app -- npm start
#   ghostty-tab-launch -s /path/to/script.fish
#
# Requirements:
#   - Ghostty terminal (https://ghostty.org)
#   - Fish shell (https://fishshell.com)
#   - The companion fish hook installed (see install.sh)
#   - gdbus (usually pre-installed on Linux with GNOME/GTK)

set -e

# ──────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────

PENDING_FILE="/tmp/ghostty-tab-pending.fish"
DBUS_DEST="com.mitchellh.ghostty"
DBUS_BASE_PATH="/com/mitchellh/ghostty/window"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ──────────────────────────────────────────────────────────────────────
# Functions
# ──────────────────────────────────────────────────────────────────────

show_help() {
    sed -n '/^# Usage:/,/^# Requirements:/{ /^# Requirements:/d; s/^# \?//; p }' "$0"
    echo ""
    echo "Install the fish hook first:  ./install.sh"
}

# Find the best Ghostty window DBus path
find_ghostty_window() {
    local preferred=$1

    if [ -n "$preferred" ]; then
        local path="$DBUS_BASE_PATH/$preferred"
        if gdbus call --session --dest "$DBUS_DEST" \
            --object-path "$path" --method org.gtk.Actions.List &>/dev/null; then
            echo "$path"
            return 0
        fi
        echo -e "${RED}Error: Ghostty window $preferred not found${NC}" >&2
        return 1
    fi

    # Auto-detect: list all Ghostty window nodes
    local all_nodes
    all_nodes=$(gdbus introspect --session --dest "$DBUS_DEST" \
        --object-path "$DBUS_BASE_PATH" 2>/dev/null \
        | grep -oP 'node \K\d+' | sort -n)

    if [ -z "$all_nodes" ]; then
        echo -e "${RED}Error: No running Ghostty window found${NC}" >&2
        return 1
    fi

    local node_count
    node_count=$(echo "$all_nodes" | wc -l)

    if [ "$node_count" -eq 1 ]; then
        # Only one window — use it
        echo "$DBUS_BASE_PATH/$all_nodes"
    elif [ -t 0 ]; then
        # Multiple windows and running interactively — prompt user to pick
        echo -e "${YELLOW}Multiple Ghostty windows detected. Use -w <N> to skip this prompt.${NC}" >&2
        echo -e "${YELLOW}Available windows: $(echo $all_nodes | tr '\n' ' ')${NC}" >&2
        local node
        select node in $all_nodes; do
            if [ -n "$node" ]; then
                echo "$DBUS_BASE_PATH/$node"
                return 0
            fi
        done
        return 1
    else
        # Multiple windows, non-interactive — use highest (most recently created)
        local node
        node=$(echo "$all_nodes" | sort -rn | head -1)
        echo "$DBUS_BASE_PATH/$node"
    fi
}

# Create a new tab via DBus
create_tab() {
    local window_path=$1

    gdbus call --session --dest "$DBUS_DEST" \
        --object-path "$window_path" \
        --method org.gtk.Actions.Activate 'new-tab' '[]' '{}' &>/dev/null
}

# Fallback: open a new Ghostty window with the command
fallback_new_window() {
    local launcher=$1

    ghostty +new-window -e fish "$launcher" &
    (sleep 5 && rm -f "$launcher") &
}

# ──────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────

work_dir=""
window_num=""
title=""
script_file=""
force_window=false
command_str=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -e)
            shift
            command_str="$1"
            shift
            ;;
        -d)
            shift
            work_dir="$1"
            shift
            ;;
        -w)
            shift
            window_num="$1"
            shift
            ;;
        -t)
            shift
            title="$1"
            shift
            ;;
        -s)
            shift
            script_file="$1"
            shift
            ;;
        -f)
            force_window=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            # Everything after -- is the command
            command_str="$*"
            break
            ;;
        *)
            # Treat remaining args as the command
            command_str="$*"
            break
            ;;
    esac
done

# Validate input
if [ -z "$command_str" ] && [ -z "$script_file" ]; then
    echo -e "${RED}Error: No command or script specified${NC}"
    echo "Usage: ghostty-tab-launch [options] [--] <command> [args...]"
    echo "       ghostty-tab-launch -s <script.fish>"
    echo ""
    echo "Run with -h for full help."
    exit 1
fi

if [ -n "$script_file" ] && [ ! -f "$script_file" ]; then
    echo -e "${RED}Error: Script file not found: $script_file${NC}"
    exit 1
fi

# Default working directory
work_dir="${work_dir:-$(pwd)}"

# ──────────────────────────────────────────────────────────────────────
# Build the pending command file
# ──────────────────────────────────────────────────────────────────────

{
    [ -n "$title" ] && echo "echo '$title'"
    echo "cd '$work_dir'"

    if [ -n "$script_file" ]; then
        echo "source '$script_file'"
    else
        echo "$command_str"
    fi
} > "$PENDING_FILE"

# ──────────────────────────────────────────────────────────────────────
# Launch
# ──────────────────────────────────────────────────────────────────────

if [ "$force_window" = true ]; then
    # Forced fallback: new window
    launcher=$(mktemp /tmp/ghostty-tab-launch-XXXXXX.fish)
    echo "#!/usr/bin/env fish" > "$launcher"
    cat "$PENDING_FILE" >> "$launcher"
    echo "exec fish" >> "$launcher"
    chmod +x "$launcher"
    rm -f "$PENDING_FILE"

    fallback_new_window "$launcher"
    echo -e "${GREEN}Ghostty window opened${NC}"
    exit 0
fi

# Try DBus tab creation
window_path=$(find_ghostty_window "$window_num") || {
    # DBus failed — fall back to new window
    echo -e "${YELLOW}DBus unavailable, falling back to new window...${NC}"

    launcher=$(mktemp /tmp/ghostty-tab-launch-XXXXXX.fish)
    echo "#!/usr/bin/env fish" > "$launcher"
    cat "$PENDING_FILE" >> "$launcher"
    echo "exec fish" >> "$launcher"
    chmod +x "$launcher"
    rm -f "$PENDING_FILE"

    fallback_new_window "$launcher"
    echo -e "${GREEN}Ghostty window opened${NC}"
    exit 0
}

create_tab "$window_path"
echo -e "${GREEN}New Ghostty tab created${NC}"
