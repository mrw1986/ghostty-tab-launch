#!/usr/bin/env bash
#
# Example: Auto-inject a prompt into Claude Code sessions
#
# Problem: Passing long prompts through tmux send-keys or Ghostty's DBus/fish
# hook chain mangles quotes and special characters.
#
# Solution: Save this script in the target directory (e.g., .claude/start.sh)
# and launch it instead of building the command inline. All quoting is handled
# in a single, controlled bash script.
#
# Usage with ghostty-tab-launch:
#   ghostty-tab-launch -e "bash /path/to/project/.claude/start.sh"
#
# Usage with tmux:
#   tmux send-keys "bash /path/to/project/.claude/start.sh" Enter
#
# Key fix: unset CLAUDECODE to prevent "nested session" errors when launched
# from within an existing Claude Code session (e.g., via tmux or subshell).

cd "$(dirname "$0")/.." || exit 1

# Prevent "nested session" error when launched from within a Claude Code session
unset CLAUDECODE

PROMPT="Your initial prompt goes here. This can be as long as needed without worrying about shell quoting issues."

exec claude --dangerously-skip-permissions "$PROMPT"
