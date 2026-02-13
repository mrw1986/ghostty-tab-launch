#!/bin/bash
#
# CraftRFP Worktree Manager
# Manages git worktrees for parallel Claude Code CLI sessions
#
# Usage: ./scripts/worktree-manager.sh <command> [options]
#
# Commands:
#   create <name> [--branch=<name>] [--launch] [--task="..."]  Create a new worktree
#   list                                                        List all worktrees
#   remove <name> [--delete-branch]                            Remove a worktree
#   ports                                                       Show port allocations
#   sync <name>                                                 Sync worktree with main
#   launch <name> [--task="..."]                               Launch Claude Code in worktree

set -e

# Configuration
MAIN_PROJECT="/home/mrw1986/Projects/craftrfp-2.0"
WORKTREE_PREFIX="craftrfp-2.0"
PROJECTS_DIR="/home/mrw1986/Projects"
REGISTRY_FILE="$MAIN_PROJECT/scripts/worktree.json"
BASE_PORT=3001  # Main uses 3000, worktrees start at 3001

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: sudo dnf install jq"
    exit 1
fi

# ── Safety: Ensure main is clean and up-to-date before branching ──

# Check for uncommitted changes to tracked files in main worktree
check_main_clean() {
    cd "$MAIN_PROJECT"
    local dirty_files
    dirty_files=$(git diff --name-only 2>/dev/null)
    local staged_files
    staged_files=$(git diff --cached --name-only 2>/dev/null)

    if [ -n "$dirty_files" ] || [ -n "$staged_files" ]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  WARNING: Main worktree has uncommitted changes!        ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        if [ -n "$dirty_files" ]; then
            echo -e "${YELLOW}Modified (unstaged):${NC}"
            echo "$dirty_files" | while read -r f; do echo "  - $f"; done
        fi
        if [ -n "$staged_files" ]; then
            echo -e "${YELLOW}Staged (uncommitted):${NC}"
            echo "$staged_files" | while read -r f; do echo "  - $f"; done
        fi
        echo ""
        echo -e "${YELLOW}These changes will NOT be in the new worktree.${NC}"
        echo -e "${YELLOW}If another session modifies these files and merges, your changes will be lost.${NC}"
        echo ""
        echo -e "${BLUE}Recommendation: Commit or stash these changes first.${NC}"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Aborted. Commit your changes first, then retry.${NC}"
            exit 1
        fi
    fi
}

# Sync main with remote (fetch + fast-forward pull)
sync_main_with_remote() {
    cd "$MAIN_PROJECT"
    echo -e "${BLUE}Syncing main branch with remote...${NC}"

    git fetch origin 2>&1 | head -5

    # Check if main is behind remote
    local local_sha
    local_sha=$(git rev-parse HEAD 2>/dev/null)
    local remote_sha
    remote_sha=$(git rev-parse origin/main 2>/dev/null)

    if [ "$local_sha" != "$remote_sha" ]; then
        local behind
        behind=$(git rev-list --count HEAD..origin/main 2>/dev/null)
        if [ "$behind" -gt 0 ]; then
            echo -e "${YELLOW}Main is $behind commit(s) behind origin/main. Pulling...${NC}"
            # Only fast-forward to avoid messing with uncommitted work
            if ! git merge --ff-only origin/main 2>&1; then
                echo -e "${RED}Fast-forward pull failed (main has diverged or has uncommitted changes).${NC}"
                echo -e "${RED}Please resolve manually: git pull origin main${NC}"
                exit 1
            fi
            echo -e "${GREEN}Main updated to $(git rev-parse --short HEAD)${NC}"
        fi
    else
        echo -e "${GREEN}Main is up to date with remote.${NC}"
    fi
}

# Initialize registry if it doesn't exist
init_registry() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        mkdir -p "$(dirname "$REGISTRY_FILE")"
        echo '{"worktrees": {}, "nextPort": 3001}' > "$REGISTRY_FILE"
    fi
}

# Get next available port
get_next_port() {
    init_registry
    jq -r '.nextPort' "$REGISTRY_FILE"
}

# Increment next port in registry
increment_port() {
    local current_port=$(get_next_port)
    local new_port=$((current_port + 1))
    local tmp=$(mktemp)
    jq ".nextPort = $new_port" "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Add worktree to registry
add_to_registry() {
    local name=$1
    local path=$2
    local branch=$3
    local port=$4
    local created=$(date -Iseconds)
    local tmp=$(mktemp)

    jq --arg name "$name" \
       --arg path "$path" \
       --arg branch "$branch" \
       --argjson port "$port" \
       --arg created "$created" \
       '.worktrees[$name] = {path: $path, branch: $branch, port: $port, created: $created}' \
       "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Remove worktree from registry
remove_from_registry() {
    local name=$1
    local tmp=$(mktemp)
    jq --arg name "$name" 'del(.worktrees[$name])' "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Get worktree info from registry
get_worktree_info() {
    local name=$1
    init_registry
    jq -r --arg name "$name" '.worktrees[$name] // empty' "$REGISTRY_FILE"
}

# Set up dependencies in worktree (node_modules + velite content types)
setup_dependencies() {
    local worktree_path=$1

    # Run full npm install to get all dependencies + run lifecycle scripts (husky, etc.)
    echo -e "${BLUE}Installing npm dependencies...${NC}"
    if [ -f "$worktree_path/package-lock.json" ]; then
        (cd "$worktree_path" && npm ci 2>&1) || {
            echo -e "${YELLOW}npm ci failed, falling back to npm install...${NC}"
            (cd "$worktree_path" && npm install 2>&1) || {
                echo -e "${RED}Warning: npm install failed. Run it manually in the worktree.${NC}"
            }
        }
    else
        (cd "$worktree_path" && npm install 2>&1) || {
            echo -e "${RED}Warning: npm install failed. Run it manually in the worktree.${NC}"
        }
    fi

    # Generate .velite content types (required for #site/content imports in blog/help pages)
    echo -e "${BLUE}Generating Velite content types...${NC}"
    (cd "$worktree_path" && npx velite build 2>&1) || {
        echo -e "${YELLOW}Warning: Velite build failed. Blog/help page type-checking may fail.${NC}"
        echo -e "${YELLOW}Run 'npx velite build' manually in the worktree if needed.${NC}"
    }
}

# Create start-dev.sh script for worktree
create_start_script() {
    local worktree_path=$1
    local name=$2
    local port=$3

    cat > "$worktree_path/start-dev.sh" << EOF
#!/bin/bash
# CraftRFP worktree dev server
# Worktree: $name
# Port: $port

set -e

# Trap to clean up background processes
cleanup() {
    if [ -n "\$VELITE_PID" ]; then
        kill \$VELITE_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "Starting CraftRFP dev server on port $port..."
echo "Access at: http://localhost:$port"

# Start velite in background
velite dev &
VELITE_PID=\$!

# Start Next.js on the worktree port
PORT=$port next dev
EOF
    chmod +x "$worktree_path/start-dev.sh"
}

# Copy environment files to worktree
copy_env_files() {
    local worktree_path=$1
    local port=$2

    # Copy main env files (prefer worktree-specific env if present)
    if [ -f "$MAIN_PROJECT/.env.worktree" ]; then
        cp "$MAIN_PROJECT/.env.worktree" "$worktree_path/.env.local"
    else
        [ -f "$MAIN_PROJECT/.env.local" ] && cp "$MAIN_PROJECT/.env.local" "$worktree_path/"
    fi
    [ -f "$MAIN_PROJECT/.env.sentry-build-plugin" ] && cp "$MAIN_PROJECT/.env.sentry-build-plugin" "$worktree_path/"
    [ -f "$MAIN_PROJECT/.mcp.json" ] && cp "$MAIN_PROJECT/.mcp.json" "$worktree_path/"

    # Symlink GCP credentials if exists
    [ -f "$MAIN_PROJECT/gcp-credentials.json" ] && ln -sf "$MAIN_PROJECT/gcp-credentials.json" "$worktree_path/gcp-credentials.json"

    # Copy all untracked files from main worktree (design docs, plans, etc.)
    # These are new files not yet committed that the worktree session may need
    local untracked_files
    untracked_files=$(cd "$MAIN_PROJECT" && git ls-files --others --exclude-standard 2>/dev/null)
    if [ -n "$untracked_files" ]; then
        local copied=0
        while IFS= read -r file; do
            # Skip env/credential files (already handled above)
            case "$file" in
                .env*|*.json|gcp-*|node_modules/*) continue ;;
            esac
            local dir
            dir=$(dirname "$file")
            mkdir -p "$worktree_path/$dir"
            cp -n "$MAIN_PROJECT/$file" "$worktree_path/$file" 2>/dev/null && copied=$((copied + 1))
        done <<< "$untracked_files"
        if [ "$copied" -gt 0 ]; then
            echo -e "${BLUE}Copied $copied untracked file(s) from main worktree${NC}"
        fi
    fi

    # Add worktree-specific settings to .env.local
    if [ -f "$worktree_path/.env.local" ]; then
        echo "" >> "$worktree_path/.env.local"
        echo "# Worktree-specific settings" >> "$worktree_path/.env.local"
        echo "PORT=$port" >> "$worktree_path/.env.local"
        echo "PLAYWRIGHT_BASE_URL=http://localhost:$port" >> "$worktree_path/.env.local"
    fi
}

# Create task context file for Claude Code to read
create_task_context() {
    local worktree_path=$1
    local name=$2
    local branch=$3
    local port=$4
    local task=$5

    # Create .claude directory
    mkdir -p "$worktree_path/.claude"

    # Create task.md with full context
    cat > "$worktree_path/.claude/task.md" << TASKFILE
# Task Context

## Worktree Information
- **Name:** $name
- **Branch:** $branch
- **Port:** $port
- **Path:** $worktree_path
- **Created:** $(date -Iseconds)

## Task Description
$task

## Startup Checklist (MANDATORY)

Before writing any code, complete these steps in order:

1. **Read this file** — understand the task and file ownership rules below
2. **Read \`docs/agent/project-context.md\`** — domain glossary, database tables, tier system, AI pipeline. This tells you what "Scribe", "Humanization", "Proposal Brain", etc. mean.
3. **Read \`docs/agent/agent-team-guidelines.md\`** — team structure, gold standard process, quality gates
4. **Read \`CLAUDE.md\`** — project conventions, critical rules, MCP servers
5. **Summarize your understanding** and ask the user to confirm before starting
6. **Spawn agent team** for non-trivial work (see Team Development below)
7. **Begin with TDD** — write failing tests first, then implement

## Team Development (MANDATORY for non-trivial work)

Use a full-stack development agent team. See \`docs/agent/agent-team-guidelines.md\` for full details.

**Spawn the following agents as needed for your task:**

| Role | Agent Type | Responsibilities |
|------|-----------|-----------------|
| Team Lead | \`general-purpose\` | Orchestrate work, assign tasks, review output, merge conflicts |
| UI/UX Engineer | \`frontend-mobile-development:frontend-developer\` | React components, Tailwind styling, responsive design, accessibility |
| Backend Engineer | \`backend-development:backend-architect\` | Server Actions, Supabase queries, DB migrations, business logic, API design |
| Workflow Engineer | \`backend-development:tdd-orchestrator\` | TDD discipline, test strategy, red-green-refactor enforcement |
| Security Auditor | \`security-scanning:security-auditor\` | OWASP review, input validation, RLS policy checks, auth flow verification |
| Code Reviewer | \`superpowers:code-reviewer\` | Review against plan and coding standards after each major step |
| Architecture Reviewer | \`code-review-ai:architect-review\` | System design, patterns, scalability, clean architecture validation |

**Not every task needs every role.** Scale the team to match the work:
- **Small fix** (1-2 files): You alone + security reviewer
- **Medium feature** (3-10 files): You + backend/frontend + code reviewer
- **Large feature/audit** (10+ files): Full team with all roles

**Process:**
1. Plan before code — \`EnterPlanMode\` for non-trivial work
2. TDD — RED (failing test) → GREEN (make pass) → REFACTOR
3. Peer review within team before marking complete
4. **Codex final review (MANDATORY)** — Load \`mcp__codex-bridge__codex_review\` via ToolSearch, run on all changed files. Fix any issues found, re-run quality gates, then have Codex review again. Keep iterating until Codex finds zero issues.
5. Verify all quality gates: \`npm run build && npm run lint && npm run test\`
6. Use \`/pr-cycle\` skill to create the PR — never manual \`gh pr create\`

## File Ownership

**CRITICAL:** If the task description above includes a SKIP LIST or file ownership rules, you MUST follow them. Never modify files owned by another worktree — note needed changes and report them instead.

## Quick Commands
\`\`\`bash
./start-dev.sh          # Start dev server on port $port
npm run build           # Build the project
npm run lint            # Run linter
npm run test            # Run tests
\`\`\`

## When Complete (ALL steps required)
1. Ensure all quality gates pass: \`npm run build && npm run lint && npm run test\`
2. **Run Codex final review loop (MANDATORY — do NOT skip):**
   - Call \`mcp__codex-bridge__codex_review\` with working_dir set to this worktree root
   - If Codex finds ANY issues: fix them, re-run quality gates (\`npm run build && npm run lint && npm run test\`), then run \`codex_review\` again
   - **Keep iterating this loop until Codex reports zero issues** — do not stop after one pass
   - You MUST complete this loop before declaring the task complete
3. **Update the sprint implementation guide** — Edit \`docs/agent/sprint-implementation-guide.md\`:
   - In the **Status table** at the top, change this sprint's row from \`PENDING\` to \`COMPLETED\` and fill in the PR number (e.g. \`#123\`)
   - The table format is: \`| <number> | <name> | COMPLETED | #<PR> | <effort> |\`
   - Only update YOUR sprint row — do not modify other sprints
4. Use \`/pr-cycle\` skill to create the PR — never manual \`gh pr create\`
5. Tell the user: "Task complete. Ready to merge \`$branch\` into main."
TASKFILE

    echo -e "${BLUE}Created task context file at .claude/task.md${NC}"

    # Create a launch script that reliably passes the prompt to Claude Code
    # This avoids quoting issues when the command goes through tmux/Ghostty/fish
    local start_script="$worktree_path/.claude/start.sh"
    cat > "$start_script" << 'STARTSCRIPT'
#!/usr/bin/env bash
# Auto-generated by worktree-manager.sh — launches Claude Code with the task prompt
cd "$(dirname "$0")/.." || exit 1

# Prevent "nested session" error when launched from within a Claude Code session
unset CLAUDECODE

PROMPT="Read .claude/task.md for your task and full context. You MUST use a full-stack agent team (spawn agents via the Task tool with team_name) as described in the task file — do NOT work solo. IMPORTANT: Before declaring done, you MUST run mcp__codex-bridge__codex_review on all changed files and iterate — fix issues, re-run quality gates, then run codex_review again — until Codex finds zero issues. This review loop is mandatory per project rules. Summarize what you understand the task to be, list which agent roles you will spawn, and ask me to confirm before you begin."

exec claude --dangerously-skip-permissions "$PROMPT"
STARTSCRIPT
    chmod +x "$start_script"
    echo -e "${BLUE}Created launch script at .claude/start.sh${NC}"
}

# Launch Claude Code in Ghostty tab
launch_in_ghostty() {
    local worktree_path=$1
    local name=$2
    local task=${3:-}
    local skip_trust=${4:-true}  # Default to true (skip trust prompt)

    local port=$(jq -r --arg n "$name" '.worktrees[$n].port' "$REGISTRY_FILE")
    local branch=$(jq -r --arg n "$name" '.worktrees[$n].branch' "$REGISTRY_FILE")

    echo -e "${BLUE}Launching Claude Code for '$name'...${NC}"

    # Build claude command with optional flags (default: skip trust)
    local claude_cmd="claude"
    if [ "$skip_trust" = true ]; then
        claude_cmd="claude --dangerously-skip-permissions"
    fi

    # Build the command to run in the new tab
    # If a start script exists (created by create_task_context), use it for reliable prompt injection
    local tab_command=""
    local start_script="$worktree_path/.claude/start.sh"
    if [ -f "$start_script" ]; then
        tab_command="bash '$start_script'"
    else
        tab_command="$claude_cmd"
    fi

    # Use ghostty-tab-launch to open a new Ghostty tab
    if command -v ghostty-tab-launch >/dev/null 2>&1; then
        ghostty-tab-launch \
            -d "$worktree_path" \
            -t "CraftRFP Worktree: $name | Branch: $branch | Port: $port" \
            -e "$tab_command"

        echo -e "${GREEN}New Ghostty tab created for '$name'${NC}"
    else
        # Fallback: try direct DBus (older method)
        echo -e "${YELLOW}ghostty-tab-launch not found, trying direct DBus...${NC}"

        local pending_file="/tmp/ghostty-worktree-pending.fish"
        cat > "$pending_file" << FISHSCRIPT
echo "CraftRFP Worktree: $name"
echo "Branch: $branch | Port: $port"
echo ""
cd '$worktree_path'
$tab_command
FISHSCRIPT

        local window_path=$(gdbus introspect --session --dest com.mitchellh.ghostty \
            --object-path /com/mitchellh/ghostty/window 2>/dev/null \
            | grep -oP 'node \K\d+' | sort -n | head -1)

        if [ -n "$window_path" ]; then
            gdbus call --session --dest com.mitchellh.ghostty \
                --object-path "/com/mitchellh/ghostty/window/$window_path" \
                --method org.gtk.Actions.Activate 'new-tab' '[]' '{}' &>/dev/null
            echo -e "${GREEN}New Ghostty tab created for '$name'${NC}"
        else
            # Final fallback: new Ghostty window
            local launcher=$(mktemp /tmp/ghostty-tab-launch-XXXXXX.fish)
            echo "#!/usr/bin/env fish" > "$launcher"
            cat "$pending_file" >> "$launcher"
            echo "exec fish" >> "$launcher"
            chmod +x "$launcher"
            rm -f "$pending_file"
            ghostty +new-window -e fish "$launcher" &
            (sleep 5 && rm -f "$launcher") &
            echo -e "${GREEN}New Ghostty window opened for '$name'${NC}"
        fi
    fi

    echo -e "  Worktree: ${BLUE}$worktree_path${NC}"
    echo -e "  Branch: ${BLUE}$branch${NC} | Port: ${BLUE}$port${NC}"
}

# Command: create
cmd_create() {
    local name=""
    local branch=""
    local launch=false
    local task=""
    local skip_trust=true  # Default to true (skip trust prompt)

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --branch=*)
                branch="${1#*=}"
                shift
                ;;
            --launch)
                launch=true
                shift
                ;;
            --task=*)
                task="${1#*=}"
                shift
                ;;
            --require-trust)
                skip_trust=false
                shift
                ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$name" ]; then
        echo -e "${RED}Error: Worktree name is required${NC}"
        echo "Usage: $0 create <name> [--branch=<name>] [--launch]"
        exit 1
    fi

    # Sanitize name (replace / with -)
    local safe_name=$(echo "$name" | tr '/' '-')

    # Set branch name (convert feature-auth to feature/auth)
    if [ -z "$branch" ]; then
        if [[ "$name" == feature-* ]]; then
            branch="feature/${name#feature-}"
        elif [[ "$name" == fix-* ]]; then
            branch="fix/${name#fix-}"
        elif [[ "$name" == bugfix-* ]]; then
            branch="bugfix/${name#bugfix-}"
        else
            branch="feature/$name"
        fi
    fi

    local worktree_path="$PROJECTS_DIR/$WORKTREE_PREFIX-$safe_name"

    # Check if worktree already exists
    if [ -d "$worktree_path" ]; then
        echo -e "${RED}Error: Worktree already exists at $worktree_path${NC}"
        exit 1
    fi

    # Check if already in registry
    if [ -n "$(get_worktree_info "$safe_name")" ]; then
        echo -e "${RED}Error: Worktree '$safe_name' already registered${NC}"
        exit 1
    fi

    # ── Pre-flight safety checks ──
    # 1. Warn if main has uncommitted tracked changes
    check_main_clean

    # 2. Sync main with remote so worktree branches from latest code
    sync_main_with_remote

    # Get port allocation
    local port=$(get_next_port)

    echo -e "${BLUE}Creating worktree '$safe_name'...${NC}"
    echo "  Path: $worktree_path"
    echo "  Branch: $branch"
    echo "  Port: $port"

    # Create git worktree (branch from current HEAD which is now up-to-date)
    cd "$MAIN_PROJECT"
    git worktree add "$worktree_path" -b "$branch" 2>/dev/null || \
    git worktree add "$worktree_path" "$branch"

    # 3. Verify the new branch is on latest main
    local main_sha
    main_sha=$(git rev-parse main 2>/dev/null)
    local branch_sha
    branch_sha=$(cd "$worktree_path" && git rev-parse HEAD 2>/dev/null)
    if [ "$main_sha" = "$branch_sha" ]; then
        echo -e "${GREEN}Verified: branch '$branch' is on latest main ($(echo $main_sha | cut -c1-7))${NC}"
    else
        echo -e "${YELLOW}Warning: branch base ($(echo $branch_sha | cut -c1-7)) differs from main ($(echo $main_sha | cut -c1-7))${NC}"
    fi

    # Copy environment files
    echo -e "${BLUE}Copying environment files...${NC}"
    copy_env_files "$worktree_path" "$port"

    # Set up dependencies (node_modules + velite)
    setup_dependencies "$worktree_path"

    # Create start script
    echo -e "${BLUE}Creating start-dev.sh...${NC}"
    create_start_script "$worktree_path" "$safe_name" "$port"

    # Create task context file if task provided
    if [ -n "$task" ]; then
        create_task_context "$worktree_path" "$safe_name" "$branch" "$port" "$task"
    fi

    # Update registry
    add_to_registry "$safe_name" "$worktree_path" "$branch" "$port"
    increment_port

    echo -e "${GREEN}Worktree created successfully!${NC}"
    echo ""
    echo "To start development:"
    echo "  cd $worktree_path"
    echo "  ./start-dev.sh"
    echo ""
    echo "Or launch Claude Code directly:"
    echo "  $0 launch $safe_name"

    # Auto-launch if requested
    if [ "$launch" = true ]; then
        launch_in_ghostty "$worktree_path" "$safe_name" "$task" "$skip_trust"
    fi
}

# Command: list
cmd_list() {
    init_registry

    echo -e "${BLUE}CraftRFP Worktrees${NC}"
    echo "=================="
    echo ""

    # Show main project
    echo -e "${GREEN}main${NC} (port 3000)"
    echo "  Path: $MAIN_PROJECT"
    echo "  Branch: $(cd "$MAIN_PROJECT" && git branch --show-current)"
    echo ""

    # Show worktrees from registry
    local worktrees=$(jq -r '.worktrees | keys[]' "$REGISTRY_FILE" 2>/dev/null)

    if [ -z "$worktrees" ]; then
        echo -e "${YELLOW}No additional worktrees registered${NC}"
    else
        for name in $worktrees; do
            local info=$(jq -r --arg n "$name" '.worktrees[$n]' "$REGISTRY_FILE")
            local path=$(echo "$info" | jq -r '.path')
            local branch=$(echo "$info" | jq -r '.branch')
            local port=$(echo "$info" | jq -r '.port')
            local created=$(echo "$info" | jq -r '.created')

            # Check if directory exists
            if [ -d "$path" ]; then
                echo -e "${GREEN}$name${NC} (port $port)"
            else
                echo -e "${RED}$name${NC} (port $port) [MISSING]"
            fi
            echo "  Path: $path"
            echo "  Branch: $branch"
            echo "  Created: $created"
            echo ""
        done
    fi
}

# Command: remove
cmd_remove() {
    local name=""
    local delete_branch=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --delete-branch)
                delete_branch=true
                shift
                ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$name" ]; then
        echo -e "${RED}Error: Worktree name is required${NC}"
        echo "Usage: $0 remove <name> [--delete-branch]"
        exit 1
    fi

    local info=$(get_worktree_info "$name")

    if [ -z "$info" ]; then
        echo -e "${RED}Error: Worktree '$name' not found in registry${NC}"
        exit 1
    fi

    local path=$(echo "$info" | jq -r '.path')
    local branch=$(echo "$info" | jq -r '.branch')

    echo -e "${YELLOW}Removing worktree '$name'...${NC}"
    echo "  Path: $path"
    echo "  Branch: $branch"

    # Check for uncommitted changes
    if [ -d "$path" ]; then
        cd "$path"
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            echo -e "${RED}Warning: Uncommitted changes detected!${NC}"
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Aborted."
                exit 1
            fi
        fi
    fi

    # Remove git worktree
    cd "$MAIN_PROJECT"
    git worktree remove "$path" --force 2>/dev/null || true

    # Delete directory if still exists
    [ -d "$path" ] && rm -rf "$path"

    # Remove from registry
    remove_from_registry "$name"

    # Optionally delete branch
    if [ "$delete_branch" = true ]; then
        echo -e "${YELLOW}Deleting branch '$branch'...${NC}"
        git branch -D "$branch" 2>/dev/null || true
    fi

    echo -e "${GREEN}Worktree removed successfully!${NC}"
}

# Command: ports
cmd_ports() {
    init_registry

    echo -e "${BLUE}Port Allocations${NC}"
    echo "================"
    echo ""
    printf "%-20s %-10s %s\n" "WORKTREE" "PORT" "URL"
    printf "%-20s %-10s %s\n" "--------" "----" "---"
    printf "%-20s %-10s %s\n" "main" "3000" "http://localhost:3000"

    local worktrees=$(jq -r '.worktrees | keys[]' "$REGISTRY_FILE" 2>/dev/null)

    for name in $worktrees; do
        local port=$(jq -r --arg n "$name" '.worktrees[$n].port' "$REGISTRY_FILE")
        printf "%-20s %-10s %s\n" "$name" "$port" "http://localhost:$port"
    done

    echo ""
    echo "Next available port: $(get_next_port)"
}

# Command: sync
cmd_sync() {
    local name=$1

    if [ -z "$name" ]; then
        echo -e "${RED}Error: Worktree name is required${NC}"
        echo "Usage: $0 sync <name>"
        exit 1
    fi

    local info=$(get_worktree_info "$name")

    if [ -z "$info" ]; then
        echo -e "${RED}Error: Worktree '$name' not found${NC}"
        exit 1
    fi

    local path=$(echo "$info" | jq -r '.path')

    if [ ! -d "$path" ]; then
        echo -e "${RED}Error: Worktree directory not found at $path${NC}"
        exit 1
    fi

    echo -e "${BLUE}Syncing worktree '$name' with main...${NC}"

    cd "$path"
    git fetch origin
    if ! git rebase origin/main 2>&1; then
        echo -e "${RED}Rebase failed — conflicts detected.${NC}"
        echo -e "${YELLOW}Resolve conflicts in $path, then run: git rebase --continue${NC}"
        echo -e "${YELLOW}Or abort with: git rebase --abort${NC}"
        exit 1
    fi

    echo -e "${GREEN}Sync complete!${NC}"
}

# Command: launch
cmd_launch() {
    local name=""
    local task=""
    local skip_trust=true  # Default to true (skip trust prompt)

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --task=*)
                task="${1#*=}"
                shift
                ;;
            --require-trust)
                skip_trust=false
                shift
                ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$name" ]; then
        echo -e "${RED}Error: Worktree name is required${NC}"
        echo "Usage: $0 launch <name> [--task=\"your task\"]"
        exit 1
    fi

    local info=$(get_worktree_info "$name")

    if [ -z "$info" ]; then
        echo -e "${RED}Error: Worktree '$name' not found${NC}"
        exit 1
    fi

    local path=$(echo "$info" | jq -r '.path')

    if [ ! -d "$path" ]; then
        echo -e "${RED}Error: Worktree directory not found at $path${NC}"
        exit 1
    fi

    launch_in_ghostty "$path" "$name" "$task" "$skip_trust"
}

# Show help
show_help() {
    cat << EOF
CraftRFP Worktree Manager

Manages git worktrees for parallel Claude Code CLI sessions.
Each worktree gets its own port allocation and isolated environment.

USAGE:
    $0 <command> [options]

COMMANDS:
    create <name> [options]    Create a new worktree
        --branch=<name>        Specify branch name (default: feature/<name>)
        --launch               Automatically launch Claude Code in new Ghostty tab
        --task="description"   Start Claude Code with this task (will ask for confirmation)
        --require-trust        Show the folder trust prompt (default: skip it)

    list                       List all worktrees with their ports

    remove <name> [options]    Remove a worktree
        --delete-branch        Also delete the git branch

    ports                      Show all port allocations

    sync <name>                Sync worktree with main branch

    launch <name> [options]    Launch Claude Code in existing worktree
        --task="description"   Start Claude Code with this task (will ask for confirmation)
        --require-trust        Show the folder trust prompt (default: skip it)

    tmux-launch <names...>     Launch multiple worktrees in tmux windows
        Creates a tmux session with one window per worktree.
        Each window auto-injects the prompt from .claude/start.sh.
        --session=<name>       tmux session name (default: craftrfp)

EXAMPLES:
    $0 create auth-refactor --launch --task="Implement OAuth2 login flow"
    $0 create payment-fix --branch=fix/payment-bug --launch
    $0 list
    $0 remove auth-refactor --delete-branch
    $0 launch auth-refactor --task="Continue working on auth feature"
    $0 tmux-launch sprint-4 sprint-6 --session=sprints

PORT ALLOCATION:
    main project: 3000
    worktrees:    3001, 3002, 3003, ...

FILES COPIED TO WORKTREES:
    .env.worktree (preferred) or .env.local (with PORT and PLAYWRIGHT_BASE_URL added)
    .env.sentry-build-plugin
    .mcp.json
    gcp-credentials.json (symlinked)
    All untracked files from main (design docs, plans, etc.)
EOF
}

# Command: tmux-launch
# Launches multiple worktrees in a single tmux session, each in its own window.
# Auto-injects the prompt via .claude/start.sh for each worktree.
cmd_tmux_launch() {
    local session_name="craftrfp"
    local worktree_names=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --session=*)
                session_name="${1#*=}"
                shift
                ;;
            *)
                worktree_names+=("$1")
                shift
                ;;
        esac
    done

    if [ ${#worktree_names[@]} -eq 0 ]; then
        echo -e "${RED}Error: At least one worktree name is required${NC}"
        echo "Usage: $0 tmux-launch <name1> [name2 ...] [--session=<name>]"
        exit 1
    fi

    # Validate all worktrees exist before creating the tmux session
    local worktree_paths=()
    for name in "${worktree_names[@]}"; do
        local info=$(get_worktree_info "$name")
        if [ -z "$info" ]; then
            echo -e "${RED}Error: Worktree '$name' not found in registry${NC}"
            exit 1
        fi
        local path=$(echo "$info" | jq -r '.path')
        if [ ! -d "$path" ]; then
            echo -e "${RED}Error: Worktree directory not found at $path${NC}"
            exit 1
        fi
        worktree_paths+=("$path")
    done

    # Kill existing session with same name if it exists
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo -e "${YELLOW}Killing existing tmux session '$session_name'...${NC}"
        tmux kill-session -t "$session_name"
    fi

    echo -e "${BLUE}Creating tmux session '$session_name' with ${#worktree_names[@]} windows...${NC}"

    # Create the first window
    local first_name="${worktree_names[0]}"
    local first_path="${worktree_paths[0]}"
    local first_start="$first_path/.claude/start.sh"

    tmux new-session -d -s "$session_name" -n "$first_name" -c "$first_path"

    # Give the shell time to initialize before sending keys
    sleep 2

    if [ -f "$first_start" ]; then
        tmux send-keys -t "$session_name:$first_name" "bash '$first_start'" Enter
        echo -e "${GREEN}  Window 0: $first_name — prompt auto-injected${NC}"
    else
        tmux send-keys -t "$session_name:$first_name" "claude --dangerously-skip-permissions" Enter
        echo -e "${YELLOW}  Window 0: $first_name — no start.sh found, launched without prompt${NC}"
    fi

    # Create additional windows
    for i in $(seq 1 $((${#worktree_names[@]} - 1))); do
        local wt_name="${worktree_names[$i]}"
        local wt_path="${worktree_paths[$i]}"
        local wt_start="$wt_path/.claude/start.sh"

        tmux new-window -t "$session_name" -n "$wt_name" -c "$wt_path"
        sleep 2

        if [ -f "$wt_start" ]; then
            tmux send-keys -t "$session_name:$wt_name" "bash '$wt_start'" Enter
            echo -e "${GREEN}  Window $i: $wt_name — prompt auto-injected${NC}"
        else
            tmux send-keys -t "$session_name:$wt_name" "claude --dangerously-skip-permissions" Enter
            echo -e "${YELLOW}  Window $i: $wt_name — no start.sh found, launched without prompt${NC}"
        fi
    done

    echo ""
    echo -e "${GREEN}tmux session '$session_name' ready with ${#worktree_names[@]} windows${NC}"
    echo -e "  Attach: ${BLUE}tmux attach -t $session_name${NC}"
    echo -e "  Switch windows: ${BLUE}Ctrl+B then 0-$((${#worktree_names[@]} - 1))${NC}"

    # Try to open in a Ghostty tab
    if command -v ghostty-tab-launch >/dev/null 2>&1; then
        ghostty-tab-launch -e "tmux attach -t $session_name"
        echo -e "${GREEN}Opened in new Ghostty tab${NC}"
    else
        # Attempt DBus fallback for Ghostty tab
        local pending_file="/tmp/ghostty-tab-pending.fish"
        cat > "$pending_file" << FISHSCRIPT
tmux attach -t $session_name
FISHSCRIPT
        local window_path=$(gdbus introspect --session --dest com.mitchellh.ghostty \
            --object-path /com/mitchellh/ghostty/window 2>/dev/null \
            | grep -oP 'node \K\d+' | sort -n | head -1)

        if [ -n "$window_path" ]; then
            gdbus call --session --dest com.mitchellh.ghostty \
                --object-path "/com/mitchellh/ghostty/window/$window_path" \
                --method org.gtk.Actions.Activate 'new-tab' '[]' '{}' &>/dev/null
            echo -e "${GREEN}Opened in new Ghostty tab${NC}"
        else
            echo -e "${YELLOW}Attach manually: tmux attach -t $session_name${NC}"
        fi
    fi
}

# Main entry point
main() {
    local command=${1:-help}
    shift 2>/dev/null || true

    case $command in
        create)
            cmd_create "$@"
            ;;
        list)
            cmd_list
            ;;
        remove)
            cmd_remove "$@"
            ;;
        ports)
            cmd_ports
            ;;
        sync)
            cmd_sync "$@"
            ;;
        launch)
            cmd_launch "$@"
            ;;
        tmux-launch)
            cmd_tmux_launch "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
