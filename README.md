# ghostty-tab-launch

Open a new [Ghostty](https://ghostty.org) tab with a specific command — from the command line.

Ghostty doesn't yet support creating tabs with commands programmatically. Its DBus `new-tab` action creates a blank tab with your default shell, and there's no `+new-tab` CLI equivalent to `+new-window -e`. This is tracked in [ghostty-org/ghostty#2353](https://github.com/ghostty-org/ghostty/discussions/2353).

**This tool bridges the gap** using a fish shell startup hook that picks up pending commands when new tabs open.

## How it works

```
ghostty-tab-launch -- htop
```

1. Writes your command to a temporary file (`/tmp/ghostty-tab-pending.fish`)
2. Creates a new tab in your current Ghostty window via DBus
3. The new tab starts fish, which sources the startup hook
4. The hook atomically claims the pending file and executes your command
5. When your command exits, you're left at a normal fish prompt

If DBus is unavailable (e.g., running over SSH or on a non-GTK build), it falls back to `ghostty +new-window -e`.

## Requirements

- [Ghostty](https://ghostty.org) terminal (Linux, GTK build)
- [Fish shell](https://fishshell.com) as your default shell in Ghostty
- `gdbus` (pre-installed on most GNOME/GTK Linux systems)

## Install

```bash
git clone https://github.com/mrw1986/ghostty-tab-launch.git
cd ghostty-tab-launch
chmod +x install.sh
./install.sh
```

This installs two files:

- `~/.config/fish/conf.d/ghostty-tab-hook.fish` — the startup hook
- `~/.local/bin/ghostty-tab-launch` — the launcher script

## Usage

```bash
# Basic: run a command in a new tab
ghostty-tab-launch -- htop

# With a working directory
ghostty-tab-launch -d ~/Projects/myapp -- npm run dev

# Using -e for the command string
ghostty-tab-launch -e "python manage.py runserver"

# With a title displayed before the command runs
ghostty-tab-launch -t "Dev Server" -d ~/app -- npm start

# Run a fish script file
ghostty-tab-launch -s ./my-setup.fish

# Target a specific Ghostty window (by DBus node number)
ghostty-tab-launch -w 2 -- htop

# Force new window instead of tab
ghostty-tab-launch -f -- htop
```

### Options

| Flag         | Description                                                |
| ------------ | ---------------------------------------------------------- |
| `-e <cmd>`   | Command to run (alternative to positional args after `--`) |
| `-d <dir>`   | Working directory (default: current directory)             |
| `-w <N>`     | Target Ghostty window number (default: auto-detect)        |
| `-t <title>` | Show a title line before running the command               |
| `-s <file>`  | Run a fish script file                                     |
| `-f`         | Force new window fallback (skip DBus)                      |
| `-h`         | Show help                                                  |

## How the hook works

When fish starts inside Ghostty, the startup hook checks for `/tmp/ghostty-tab-pending.fish`. If found, it atomically renames (claims) the file and sources it. Since `mv` on the same filesystem is an atomic `rename(2)` syscall, only one tab can claim a given pending file — preventing race conditions if multiple tabs open simultaneously.

```fish
# ~/.config/fish/conf.d/ghostty-tab-hook.fish
if status is-interactive; and test "$TERM_PROGRAM" = ghostty
    set -l pending /tmp/ghostty-tab-pending.fish
    if test -f "$pending"
        set -l claimed /tmp/ghostty-tab-claimed-$fish_pid.fish
        if command mv "$pending" "$claimed" 2>/dev/null
            source "$claimed"
            command rm -f "$claimed"
        end
    end
end
```

## Examples

The `examples/` directory contains real-world usage patterns:

- **`start-session.sh`** — Template for auto-injecting prompts into Claude Code sessions. Solves quoting issues when long command strings pass through tmux/DBus/fish chains.
- **`worktree-manager.sh`** — Full git worktree manager for parallel Claude Code sessions. Demonstrates `ghostty-tab-launch` integration, tmux multi-window launch, and the start-script pattern.

### Key patterns

**Long commands via wrapper script:** Instead of passing long strings through `-e`, save a bash script and launch it:

```bash
# Instead of this (breaks with special characters):
ghostty-tab-launch -e "claude --dangerously-skip-permissions 'very long prompt...'"

# Do this:
ghostty-tab-launch -e "bash /path/to/project/.claude/start.sh"
```

**Nested session prevention:** When launching from inside Claude Code (or any tool that sets environment markers), unset the marker in your wrapper script:

```bash
#!/usr/bin/env bash
unset CLAUDECODE  # Prevents "nested session" error
exec claude --dangerously-skip-permissions "$PROMPT"
```

**tmux multi-session with ghostty-tab-launch:** Create a tmux session, then open it in a Ghostty tab:

```bash
tmux new-session -d -s mywork -n window1 -c /path/to/project1
tmux send-keys -t mywork:window1 "bash .claude/start.sh" Enter

tmux new-window -t mywork -n window2 -c /path/to/project2
sleep 2  # Let shell initialize before send-keys
tmux send-keys -t mywork:window2 "bash .claude/start.sh" Enter

ghostty-tab-launch -e "tmux attach -t mywork"
```

## Limitations

- **Fish shell only** — the startup hook is fish-specific. Bash/zsh would need equivalent `~/.bashrc`/`~/.zshrc` hooks.
- **One pending command at a time** — if you call `ghostty-tab-launch` twice before the first tab starts, the second call overwrites the first. In practice this isn't an issue since tab creation is near-instant.
- **Linux GTK only** — the DBus approach only works on the GTK (Linux) build of Ghostty. macOS uses a different IPC mechanism.

## When this becomes unnecessary

Once [ghostty-org/ghostty#2353](https://github.com/ghostty-org/ghostty/discussions/2353) is implemented, Ghostty will have a proper scripting API. At that point, this tool can be replaced with something like:

```bash
ghostty +new-tab -e htop          # hypothetical future API
```

## Uninstall

```bash
./uninstall.sh
```

## License

MIT
