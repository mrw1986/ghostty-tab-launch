# ghostty-tab-launch — Fish startup hook
#
# Checks for a pending command file written by ghostty-tab-launch.sh
# and executes it when a new Ghostty tab opens.
#
# Install: copy to ~/.config/fish/conf.d/ghostty-tab-hook.fish
# Or run:  ./install.sh

if status is-interactive; and test "$TERM_PROGRAM" = ghostty
    set -l pending /tmp/ghostty-tab-pending.fish
    if test -f "$pending"
        # Atomically claim the file (rename is atomic on same filesystem)
        set -l claimed /tmp/ghostty-tab-claimed-$fish_pid.fish
        if command mv "$pending" "$claimed" 2>/dev/null
            source "$claimed"
            command rm -f "$claimed"
        end
    end
end
