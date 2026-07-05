#!/usr/bin/env bash
#
# claude-queue - Automated GitHub issue solver & creator
#
# Commands:
#   claude-queue [options]         Solve open issues (default)
#   claude-queue create [options]  Create issues from text or interactively
#
# Solve options:
#   --issue ID         Solve specific issue(s) by ID, URL, or comma-separated IDs
#   --max-retries N    Max retries per issue (default: 3)
#   --max-turns N      Max Claude turns per attempt (default: 50)
#   --label LABEL      Only process issues with this label (can be repeated)
#   --branch BRANCH    Work on this branch instead of creating a new one
#   --model MODEL      Claude model to use
#   -v, --version      Show version
#   -h, --help         Show this help message
#
# Create options:
#   -i, --interactive  Interview mode (Claude asks questions)
#   --label LABEL      Add this label to all created issues
#   --model MODEL      Claude model to use
#   -h, --help         Show help for create

set -euo pipefail

VERSION=$(node -p "require('$(dirname "$0")/package.json').version" 2>/dev/null || echo "unknown")

MAX_RETRIES=3
MAX_TURNS=50
declare -a ISSUE_FILTERS=()
ISSUE_IDS=""
MODEL_FLAG=""
BRANCH_OVERRIDE=""
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%H%M%S)
BRANCH="claude-queue/${DATE}"
LOG_DIR="/tmp/claude-queue-${DATE}-${TIMESTAMP}"

LABEL_PROGRESS="claude-queue:in-progress"
LABEL_SOLVED="claude-queue:solved"
LABEL_FAILED="claude-queue:failed"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

declare -a SOLVED_ISSUES=()
declare -a FAILED_ISSUES=()
declare -a SKIPPED_ISSUES=()
CURRENT_ISSUE=""
CHILD_PID=""
START_TIME=$(date +%s)

show_help() {
    echo "claude-queue v${VERSION} — Automated GitHub issue solver & creator"
    echo ""
    echo "Usage:"
    echo "  claude-queue [options]              Solve open issues (default)"
    echo "  claude-queue create [options] [text] Create issues from text or interactively"
    echo ""
    echo "Solve options:"
    echo "  --issue ID         Solve specific issue(s) by ID, URL, or comma-separated IDs"
    echo "  --max-retries N    Max retries per issue (default: 3)"
    echo "  --max-turns N      Max Claude turns per attempt (default: 50)"
    echo "  --label LABEL      Only process issues with this label (can be repeated)"
    echo "  --branch BRANCH    Work on this branch instead of creating a new one"
    echo "  --model MODEL      Claude model to use"
    echo "  -v, --version      Show version"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Run 'claude-queue create --help' for create options."
}

show_create_help() {
    echo "claude-queue create — Generate GitHub issues from text or an interactive interview"
    echo ""
    echo "Usage:"
    echo "  claude-queue create \"description\"     Create issues from inline text"
    echo "  claude-queue create                    Prompt for text input (Ctrl+D to finish)"
    echo "  claude-queue create -i                 Interactive interview mode"
    echo ""
    echo "Options:"
    echo "  -i, --interactive  Interview mode (Claude asks clarifying questions first)"
    echo "  --label LABEL      Add this label to every created issue"
    echo "  --model MODEL      Claude model to use"
    echo "  -h, --help         Show this help message"
}

log()         { echo -e "${DIM}$(date +%H:%M:%S)${NC} ${BLUE}[claude-queue]${NC} $1"; }
log_success() { echo -e "${DIM}$(date +%H:%M:%S)${NC} ${GREEN}[claude-queue]${NC} $1"; }
log_warn()    { echo -e "${DIM}$(date +%H:%M:%S)${NC} ${YELLOW}[claude-queue]${NC} $1"; }
log_error()   { echo -e "${DIM}$(date +%H:%M:%S)${NC} ${RED}[claude-queue]${NC} $1"; }
log_header()  { echo -e "\n${BOLD}═══ $1 ═══${NC}\n"; }

cleanup() {
    local exit_code=$?

    if [ -n "$CURRENT_ISSUE" ]; then
        log_warn "Interrupted while working on issue #${CURRENT_ISSUE}"
        gh issue edit "$CURRENT_ISSUE" --remove-label "$LABEL_PROGRESS" 2>/dev/null || true
        gh issue edit "$CURRENT_ISSUE" --add-label "$LABEL_FAILED" 2>/dev/null || true
    fi

    if [ $exit_code -ne 0 ] && [ ${#SOLVED_ISSUES[@]} -gt 0 ]; then
        log_warn "Script interrupted but ${#SOLVED_ISSUES[@]} issue(s) were solved."
        log_warn "Branch '${BRANCH}' has your commits. Push manually if needed."
    fi

    if [ -d "$LOG_DIR" ]; then
        log "Logs saved to: ${LOG_DIR}"
    fi
}

handle_interrupt() {
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    CHILD_PID=""
    exit 130
}

trap handle_interrupt INT TERM
trap cleanup EXIT

preflight() {
    log_header "Preflight Checks"

    local failed=false

    for cmd in gh claude git jq; do
        if command -v "$cmd" &>/dev/null; then
            log "  $cmd ... found"
        else
            log_error "  $cmd ... NOT FOUND"
            failed=true
        fi
    done

    if ! gh auth status &>/dev/null; then
        log_error "  gh auth ... not authenticated"
        failed=true
    else
        log "  gh auth ... ok"
    fi

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log_error "  git repo ... not inside a git repository"
        failed=true
    else
        log "  git repo ... ok"
    fi

    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        log_error "  working tree ... dirty (commit or stash changes first)"
        failed=true
    else
        log "  working tree ... clean"
    fi

    if [ "$failed" = true ]; then
        log_error "Preflight failed. Aborting."
        exit 1
    fi

    mkdir -p "$LOG_DIR"
    log "  log dir ... ${LOG_DIR}"
}

ensure_labels() {
    log "Creating labels (if missing)..."

    gh label create "$LABEL_PROGRESS" --color "fbca04" --description "claude-queue is working on this"  --force 2>/dev/null || true
    gh label create "$LABEL_SOLVED"   --color "0e8a16" --description "Solved by claude-queue"           --force 2>/dev/null || true
    gh label create "$LABEL_FAILED"   --color "d93f0b" --description "claude-queue could not solve this" --force 2>/dev/null || true
}

setup_branch() {
    log_header "Branch Setup"

    local default_branch
    default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')
    log "Default branch: ${default_branch}"

    git fetch origin "$default_branch" --quiet

    if [ -n "$BRANCH_OVERRIDE" ]; then
        BRANCH="$BRANCH_OVERRIDE"

        if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
            git checkout "$BRANCH" --quiet
            log_success "Using existing branch: ${BRANCH}"
        elif git ls-remote --exit-code --heads origin "$BRANCH" &>/dev/null; then
            git fetch origin "$BRANCH" --quiet
            git checkout -b "$BRANCH" "origin/${BRANCH}" --quiet
            log_success "Checked out branch from origin: ${BRANCH}"
        else
            git checkout -b "$BRANCH" "origin/${default_branch}" --quiet
            log_success "Created branch: ${BRANCH}"
        fi

        return
    fi

    if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
        log_warn "Branch ${BRANCH} already exists, adding timestamp suffix"
        BRANCH="${BRANCH}-${TIMESTAMP}"
    fi

    git checkout -b "$BRANCH" "origin/${default_branch}" --quiet
    log_success "Created branch: ${BRANCH}"
}

fetch_issues() {
    local args=(--state open --json "number,title,body,labels" --limit 200 --search "sort:created-asc")

    for filter in "${ISSUE_FILTERS[@]}"; do
        args+=(--label "$filter")
    done

    gh issue list "${args[@]}"
}

parse_issue_number() {
    local input="$1"

    local num
    num=$(echo "$input" | grep -oE '[0-9]+$' || echo "")

    if [ -z "$num" ]; then
        log_error "Invalid issue identifier: $input"
        return 1
    fi

    echo "$num"
}

fetch_specific_issues() {
    local ids_str="$1"
    local result="["
    local first=true

    IFS=',' read -ra id_array <<< "$ids_str"
    for id in "${id_array[@]}"; do
        id=$(echo "$id" | xargs)

        local num
        if ! num=$(parse_issue_number "$id"); then
            continue
        fi

        local issue_json
        issue_json=$(gh issue view "$num" --json "number,title,body,labels" 2>/dev/null) || {
            log_error "Could not fetch issue #${num}"
            continue
        }

        if [ "$first" = true ]; then
            first=false
        else
            result+=","
        fi
        result+="$issue_json"
    done

    result+="]"
    echo "$result"
}

process_issue() {
    local issue_number=$1
    local issue_title="$2"
    local attempt=0
    local solved=false
    local issue_log="${LOG_DIR}/issue-${issue_number}.md"
    local checkpoint
    checkpoint=$(git rev-parse HEAD)

    CURRENT_ISSUE="$issue_number"

    log_header "Issue #${issue_number}: ${issue_title}"

    gh issue edit "$issue_number" \
        --remove-label "$LABEL_SOLVED" \
        --remove-label "$LABEL_FAILED" \
        2>/dev/null || true
    gh issue edit "$issue_number" --add-label "$LABEL_PROGRESS"

    {
        echo "# Issue #${issue_number}: ${issue_title}"
        echo ""
        echo "**Started:** $(date)"
        echo ""
    } > "$issue_log"

    while [ "$attempt" -lt "$MAX_RETRIES" ] && [ "$solved" = false ]; do
        attempt=$((attempt + 1))
        log "Attempt ${attempt}/${MAX_RETRIES}"

        git reset --hard "$checkpoint" --quiet 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true

        echo "## Attempt ${attempt}" >> "$issue_log"
        echo "" >> "$issue_log"

        local custom_instructions=""
        if [ -f ".claude-queue" ]; then
            custom_instructions="

Additional project-specific instructions:
$(cat .claude-queue)"
        fi

        local prompt
        prompt="You are an automated assistant solving a GitHub issue in this repository.

First, read the full issue details by running:
  gh issue view ${issue_number}

Then:
1. Explore the codebase to understand the project structure and conventions
2. Implement a complete, correct fix for the issue
3. Run any existing tests to verify your fix doesn't break anything
4. If tests fail because of your changes, fix them

Rules:
- Do NOT create any git commits
- Do NOT push anything
- Match the existing code style exactly
- Only change what is necessary to solve the issue
${custom_instructions}
If this issue does NOT require code changes (e.g. it's a question, a request for external action,
a finding, or something that can't be solved with code), output a line that says CLAUDE_QUEUE_NO_CODE
followed by an explanation of what needs to be done instead.

Otherwise, when you are done, output a line that says CLAUDE_QUEUE_SUMMARY followed by a 2-3 sentence
description of what you changed and why."

        local attempt_log="${LOG_DIR}/issue-${issue_number}-attempt-${attempt}.log"
        local claude_exit=0

        # shellcheck disable=SC2086
        claude -p "$prompt" \
            --dangerously-skip-permissions \
            --max-turns "$MAX_TURNS" \
            $MODEL_FLAG \
            > "$attempt_log" 2>&1 &
        CHILD_PID=$!
        wait "$CHILD_PID" || claude_exit=$?
        CHILD_PID=""

        if [ "$claude_exit" -ne 0 ]; then
            log_warn "Claude exited with code ${claude_exit}"
            echo "**Claude exited with code ${claude_exit}**" >> "$issue_log"
            echo "" >> "$issue_log"
            continue
        fi

        local no_code_reason
        no_code_reason=$(grep -A 20 "CLAUDE_QUEUE_NO_CODE" "$attempt_log" 2>/dev/null | tail -n +2 | head -10 || echo "")

        if [ -n "$no_code_reason" ]; then
            log "Issue does not require code changes"
            {
                echo "### No Code Changes Required"
                echo "$no_code_reason"
                echo ""
            } >> "$issue_log"
            solved=true
            log_success "Issue #${issue_number} handled (no code changes needed)"
            break
        fi

        local changed_files
        changed_files=$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)

        if [ -z "$changed_files" ]; then
            log_warn "No file changes detected"
            echo "**No file changes detected**" >> "$issue_log"
            echo "" >> "$issue_log"
            continue
        fi

        log_success "Changes detected in:"
        echo "$changed_files" | while IFS= read -r f; do
            log "  ${f}"
        done

        local summary
        summary=$(grep -A 20 "CLAUDE_QUEUE_SUMMARY" "$attempt_log" 2>/dev/null | tail -n +2 | head -10 || echo "No summary provided.")

        {
            echo "### Summary"
            echo "$summary"
            echo ""
            echo "### Changed Files"
            echo "$changed_files" | while IFS= read -r f; do echo "- \`${f}\`"; done
            echo ""
        } >> "$issue_log"

        git add -A
        git commit -m "fix: resolve #${issue_number} - ${issue_title}

Automated fix by claude-queue.
Closes #${issue_number}" --quiet

        solved=true

        log_success "Solved issue #${issue_number} on attempt ${attempt}"
    done

    gh issue edit "$issue_number" --remove-label "$LABEL_PROGRESS" 2>/dev/null || true

    {
        echo "**Finished:** $(date)"
        echo "**Status:** $([ "$solved" = true ] && echo "SOLVED" || echo "FAILED after ${MAX_RETRIES} attempts")"
    } >> "$issue_log"

    if [ "$solved" = true ]; then
        gh issue edit "$issue_number" --add-label "$LABEL_SOLVED"
        gh issue comment "$issue_number" --body-file "$issue_log" 2>/dev/null || true
        SOLVED_ISSUES+=("${issue_number}|${issue_title}")
    else
        gh issue edit "$issue_number" --add-label "$LABEL_FAILED"
        gh issue comment "$issue_number" --body "claude-queue failed to solve this issue after ${MAX_RETRIES} attempts." 2>/dev/null || true
        FAILED_ISSUES+=("${issue_number}|${issue_title}")
        git reset --hard "$checkpoint" --quiet 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true
    fi

    CURRENT_ISSUE=""
}

review_and_fix() {
    log_header "Final Review & Fix Pass"

    local review_log="${LOG_DIR}/review.md"

    local prompt
    prompt="You are doing a final review pass on automated code changes in this repository.

Look at all uncommitted and recently committed changes on this branch. For each file that was modified:
1. Read the full file
2. Check for bugs, incomplete implementations, lazy code, missed edge cases, or style inconsistencies
3. Fix anything you find

Rules:
- Do NOT create any git commits
- Do NOT push anything
- Only fix real problems, don't refactor for style preferences
- Match the existing code style exactly

When you are done, output a line that says CLAUDE_QUEUE_REVIEW followed by a brief summary of what you fixed. If nothing needed fixing, say so."

    # shellcheck disable=SC2086
    claude -p "$prompt" \
        --dangerously-skip-permissions \
        --max-turns "$MAX_TURNS" \
        $MODEL_FLAG \
        > "$review_log" 2>&1 &
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""

    local changed_files
    changed_files=$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)

    if [ -n "$changed_files" ]; then
        log_success "Review pass made fixes:"
        echo "$changed_files" | while IFS= read -r f; do
            log "  ${f}"
        done

        git add -A
        git commit -m "chore: final review pass

Automated review and fixes by claude-queue." --quiet
    else
        log "Review pass found nothing to fix"
    fi
}

create_pr() {
    log_header "Creating Pull Request"

    local default_branch
    default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')
    local elapsed=$(( $(date +%s) - START_TIME ))
    local duration
    duration="$(( elapsed / 3600 ))h $(( (elapsed % 3600) / 60 ))m $(( elapsed % 60 ))s"
    local pr_body="${LOG_DIR}/pr-body.md"
    local total_processed=$(( ${#SOLVED_ISSUES[@]} + ${#FAILED_ISSUES[@]} ))

    {
        echo "## claude-queue Run Summary"
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Date | ${DATE} |"
        echo "| Duration | ${duration} |"
        echo "| Issues processed | ${total_processed} |"
        echo "| Solved | ${#SOLVED_ISSUES[@]} |"
        echo "| Failed | ${#FAILED_ISSUES[@]} |"
        echo "| Skipped | ${#SKIPPED_ISSUES[@]} |"
        echo ""

        if [ ${#SOLVED_ISSUES[@]} -gt 0 ]; then
            echo "### Solved Issues"
            echo ""
            echo "| Issue | Title |"
            echo "|-------|-------|"
            for entry in "${SOLVED_ISSUES[@]}"; do
                local num="${entry%%|*}"
                local title="${entry#*|}"
                echo "| #${num} | ${title} |"
            done
            echo ""
        fi

        if [ ${#FAILED_ISSUES[@]} -gt 0 ]; then
            echo "### Failed Issues"
            echo ""
            echo "| Issue | Title |"
            echo "|-------|-------|"
            for entry in "${FAILED_ISSUES[@]}"; do
                local num="${entry%%|*}"
                local title="${entry#*|}"
                echo "| #${num} | ${title} |"
            done
            echo ""
        fi

        echo "---"
        echo ""
        echo "### Chain Logs"
        echo ""

        for log_file in "${LOG_DIR}"/issue-*.md; do
            if [ ! -f "$log_file" ]; then
                continue
            fi

            local issue_num
            issue_num=$(basename "$log_file" | grep -oE '[0-9]+')

            echo "<details>"
            echo "<summary>Issue #${issue_num} Log</summary>"
            echo ""
            head -c 40000 "$log_file"
            echo ""
            echo "</details>"
            echo ""
        done
    } > "$pr_body"

    local body_size
    body_size=$(wc -c < "$pr_body")
    if [ "$body_size" -gt 60000 ]; then
        log_warn "PR body is ${body_size} bytes, truncating to fit GitHub limits"
        head -c 59000 "$pr_body" > "${pr_body}.tmp"
        {
            echo ""
            echo ""
            echo "---"
            echo "*Log truncated. Full logs available at: ${LOG_DIR}*"
        } >> "${pr_body}.tmp"
        mv "${pr_body}.tmp" "$pr_body"
    fi

    git push origin "$BRANCH" --quiet
    log_success "Pushed branch to origin"

    local existing_pr
    existing_pr=$(gh pr list --head "$BRANCH" --state open --json url -q '.[0].url' 2>/dev/null || echo "")

    if [ -n "$existing_pr" ]; then
        gh pr comment "$existing_pr" --body-file "$pr_body" 2>/dev/null || true
        log_success "Updated existing pull request: ${existing_pr}"
        return
    fi

    local pr_url
    pr_url=$(gh pr create \
        --base "$default_branch" \
        --head "$BRANCH" \
        --title "claude-queue: Automated fixes (${DATE})" \
        --body-file "$pr_body")

    log_success "Pull request created: ${pr_url}"
}

main() {
    echo -e "${BOLD}"
    echo '       _                 _                                  '
    echo '   ___| | __ _ _   _  __| | ___        __ _ _   _  ___ _   _  ___'
    echo '  / __| |/ _` | | | |/ _` |/ _ \_____ / _` | | | |/ _ \ | | |/ _ \'
    echo ' | (__| | (_| | |_| | (_| |  __/_____| (_| | |_| |  __/ |_| |  __/'
    echo '  \___|_|\__,_|\__,_|\__,_|\___|      \__, |\__,_|\___|\__,_|\___|'
    echo '                                         |_|                      '
    echo -e "${NC}"
    echo -e "  ${DIM}Automated GitHub issue solver${NC}"
    echo ""

    preflight
    ensure_labels
    setup_branch

    log_header "Fetching Issues"

    local issues
    if [ -n "$ISSUE_IDS" ]; then
        log "Fetching specific issue(s): ${ISSUE_IDS}"
        issues=$(fetch_specific_issues "$ISSUE_IDS")
    else
        issues=$(fetch_issues)
    fi
    local total
    total=$(echo "$issues" | jq length)

    if [ "$total" -eq 0 ]; then
        log "No open issues found. Going back to sleep."
        exit 0
    fi

    log "Found ${total} open issue(s)"

    for i in $(seq 0 $((total - 1))); do
        local number title labels
        number=$(echo "$issues" | jq -r ".[$i].number")
        title=$(echo "$issues" | jq -r ".[$i].title")
        labels=$(echo "$issues" | jq -r "[.[$i].labels[].name] | join(\",\")" 2>/dev/null || echo "")

        if [ -z "$ISSUE_IDS" ] && echo "$labels" | grep -q "claude-queue:"; then
            log "Skipping #${number} (already has a claude-queue label)"
            SKIPPED_ISSUES+=("${number}|${title}")
            continue
        fi

        process_issue "$number" "$title" || true
    done

    if [ ${#SOLVED_ISSUES[@]} -gt 0 ]; then
        review_and_fix
        create_pr
    else
        log_warn "No issues were solved. No PR created."
    fi

    log_header "claude-queue Complete"

    local elapsed=$(( $(date +%s) - START_TIME ))
    log "Duration: $(( elapsed / 3600 ))h $(( (elapsed % 3600) / 60 ))m $(( elapsed % 60 ))s"
    log_success "Solved: ${#SOLVED_ISSUES[@]}"
    if [ ${#FAILED_ISSUES[@]} -gt 0 ]; then
        log_error "Failed: ${#FAILED_ISSUES[@]}"
    fi
    if [ ${#SKIPPED_ISSUES[@]} -gt 0 ]; then
        log_warn "Skipped: ${#SKIPPED_ISSUES[@]}"
    fi
    log "Logs: ${LOG_DIR}"
}

create_preflight() {
    log_header "Preflight Checks"

    local failed=false

    for cmd in gh claude jq; do
        if command -v "$cmd" &>/dev/null; then
            log "  $cmd ... found"
        else
            log_error "  $cmd ... NOT FOUND"
            failed=true
        fi
    done

    if ! gh auth status &>/dev/null; then
        log_error "  gh auth ... not authenticated"
        failed=true
    else
        log "  gh auth ... ok"
    fi

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log_error "  git repo ... not inside a git repository"
        failed=true
    else
        log "  git repo ... ok"
    fi

    if [ "$failed" = true ]; then
        log_error "Preflight failed. Aborting."
        exit 1
    fi
}

get_repo_labels() {
    gh label list --json name -q '.[].name' 2>/dev/null | paste -sd ',' -
}

extract_json() {
    local input="$1"
    local json

    json=$(echo "$input" | sed -n '/^```\(json\)\?$/,/^```$/{ /^```/d; p; }')
    if [ -z "$json" ]; then
        json="$input"
    fi

    if echo "$json" | jq empty 2>/dev/null; then
        echo "$json"
        return 0
    fi

    json=$(echo "$input" | grep -o '\[.*\]' | head -1)
    if [ -n "$json" ] && echo "$json" | jq empty 2>/dev/null; then
        echo "$json"
        return 0
    fi

    return 1
}

create_from_text() {
    local user_text="$1"
    local repo_labels
    repo_labels=$(get_repo_labels)

    log "Analyzing text and generating issues..."

    local prompt
    prompt="You are a GitHub issue planner. The user wants to create issues for a repository.

Existing labels in the repo: ${repo_labels}

The user's description:
${user_text}

Decompose this into a JSON array of well-structured GitHub issues. Each issue should have:
- \"title\": a clear, concise issue title
- \"body\": a detailed issue body in markdown (include acceptance criteria where appropriate)
- \"labels\": an array of label strings (reuse existing repo labels when they fit, or suggest new ones)

Rules:
- Create separate issues for logically distinct tasks
- Each issue should be independently actionable
- Use clear, imperative titles (e.g. \"Add dark mode toggle to settings page\")
- If the description is vague, make reasonable assumptions and note them in the body

Output ONLY the JSON array, no other text."

    local output
    # shellcheck disable=SC2086
    output=$(claude -p "$prompt" $MODEL_FLAG 2>/dev/null)

    local json
    if ! json=$(extract_json "$output"); then
        log_error "Failed to parse Claude's response as JSON"
        log_error "Raw output:"
        echo "$output"
        exit 1
    fi

    local count
    count=$(echo "$json" | jq length)
    if [ "$count" -eq 0 ]; then
        log_error "No issues were generated"
        exit 1
    fi

    echo "$json"
}

create_interactive() {
    local repo_labels
    repo_labels=$(get_repo_labels)
    local conversation=""
    local max_turns=10
    local turn=0

    local system_prompt="You are a GitHub issue planner conducting an interview to understand what issues to create for a repository.

Existing labels in the repo: ${repo_labels}

Your job:
1. Ask focused questions to understand what the user wants to build or fix
2. Ask about priorities, scope, and acceptance criteria
3. When you have enough information, output the marker CLAUDE_QUEUE_READY on its own line, followed by a JSON array of issues

Each issue in the JSON array should have:
- \"title\": a clear, concise issue title
- \"body\": a detailed issue body in markdown
- \"labels\": an array of label strings (reuse existing repo labels when they fit)

Rules:
- Ask one question at a time
- Keep questions short and specific
- After 2-3 questions you should have enough context — don't over-interview
- If the user says \"done\", immediately generate the issues with what you know
- Output ONLY your question text (no JSON) until you're ready to generate issues
- When ready, output CLAUDE_QUEUE_READY on its own line followed by ONLY the JSON array"

    echo -e "${BOLD}Interactive issue creation${NC}"
    echo -e "${DIM}Answer Claude's questions. Type 'done' to generate issues at any time.${NC}"
    echo ""

    while [ "$turn" -lt "$max_turns" ]; do
        turn=$((turn + 1))

        local prompt
        if [ -z "$conversation" ]; then
            prompt="${system_prompt}

Start by asking your first question."
        else
            prompt="${system_prompt}

Conversation so far:
${conversation}

Continue the interview or, if you have enough information, output CLAUDE_QUEUE_READY followed by the JSON array."
        fi

        local output
        # shellcheck disable=SC2086
        output=$(claude -p "$prompt" $MODEL_FLAG 2>/dev/null)

        if echo "$output" | grep -q "CLAUDE_QUEUE_READY"; then
            local json_part
            json_part=$(echo "$output" | sed -n '/CLAUDE_QUEUE_READY/,$ p' | tail -n +2)

            local json
            if ! json=$(extract_json "$json_part"); then
                log_error "Failed to parse generated issues as JSON"
                exit 1
            fi

            echo "$json"
            return 0
        fi

        echo -e "${BLUE}Claude:${NC} ${output}"
        echo ""

        local user_input
        read -r -p "You: " user_input

        if [ "$user_input" = "done" ]; then
            conversation="${conversation}
Claude: ${output}
User: Please generate the issues now with what you know."

            local final_prompt="${system_prompt}

Conversation so far:
${conversation}

The user wants you to generate the issues now. Output CLAUDE_QUEUE_READY followed by the JSON array."

            local final_output
            # shellcheck disable=SC2086
            final_output=$(claude -p "$final_prompt" $MODEL_FLAG 2>/dev/null)

            local final_json_part
            final_json_part=$(echo "$final_output" | sed -n '/CLAUDE_QUEUE_READY/,$ p' | tail -n +2)
            if [ -z "$final_json_part" ]; then
                final_json_part="$final_output"
            fi

            local json
            if ! json=$(extract_json "$final_json_part"); then
                log_error "Failed to parse generated issues as JSON"
                exit 1
            fi

            echo "$json"
            return 0
        fi

        conversation="${conversation}
Claude: ${output}
User: ${user_input}"
    done

    log_warn "Reached maximum interview turns, generating issues with current information..."

    local final_prompt="${system_prompt}

Conversation so far:
${conversation}

You've reached the maximum number of questions. Output CLAUDE_QUEUE_READY followed by the JSON array now."

    local final_output
    # shellcheck disable=SC2086
    final_output=$(claude -p "$final_prompt" $MODEL_FLAG 2>/dev/null)

    local final_json_part
    final_json_part=$(echo "$final_output" | sed -n '/CLAUDE_QUEUE_READY/,$ p' | tail -n +2)
    if [ -z "$final_json_part" ]; then
        final_json_part="$final_output"
    fi

    local json
    if ! json=$(extract_json "$final_json_part"); then
        log_error "Failed to parse generated issues as JSON"
        exit 1
    fi

    echo "$json"
}

preview_issues() {
    local json="$1"
    local count
    count=$(echo "$json" | jq length)

    echo ""
    echo -e "${BOLD}═══ Issue Preview ═══${NC}"
    echo ""

    for i in $(seq 0 $((count - 1))); do
        local title labels body
        title=$(echo "$json" | jq -r ".[$i].title")
        labels=$(echo "$json" | jq -r ".[$i].labels // [] | join(\", \")")
        body=$(echo "$json" | jq -r ".[$i].body" | head -3)

        echo -e "  ${BOLD}$((i + 1)). ${title}${NC}"
        if [ -n "$labels" ]; then
            echo -e "     ${DIM}Labels: ${labels}${NC}"
        fi
        echo -e "     ${DIM}$(echo "$body" | head -1)${NC}"
        echo ""
    done
}

confirm_and_create() {
    local json="$1"
    local extra_label="$2"
    local count
    count=$(echo "$json" | jq length)

    local prompt_text="Create ${count} issue(s)? [y/N] "
    read -r -p "$prompt_text" confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "Cancelled."
        exit 0
    fi

    echo ""

    for i in $(seq 0 $((count - 1))); do
        local title body
        title=$(echo "$json" | jq -r ".[$i].title")
        body=$(echo "$json" | jq -r ".[$i].body")

        local label_args=()
        local issue_labels
        issue_labels=$(echo "$json" | jq -r ".[$i].labels // [] | .[]")
        while IFS= read -r lbl; do
            if [ -n "$lbl" ]; then
                label_args+=(--label "$lbl")
            fi
        done <<< "$issue_labels"

        if [ -n "$extra_label" ]; then
            label_args+=(--label "$extra_label")
        fi

        local issue_url
        issue_url=$(gh issue create --title "$title" --body "$body" "${label_args[@]}" 2>&1)
        log_success "Created: ${issue_url}"
    done

    echo ""
    log_success "Created ${count} issue(s)"
}

cmd_create() {
    local interactive=false
    local extra_label=""
    local user_text=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--interactive) interactive=true; shift ;;
            --label)          extra_label="$2"; shift 2 ;;
            --model)          MODEL_FLAG="--model $2"; shift 2 ;;
            -h|--help)        show_create_help; exit 0 ;;
            -*)               echo "Unknown option: $1"; echo ""; show_create_help; exit 1 ;;
            *)                user_text="$1"; shift ;;
        esac
    done

    create_preflight

    local json

    if [ "$interactive" = true ]; then
        json=$(create_interactive)
    elif [ -n "$user_text" ]; then
        json=$(create_from_text "$user_text")
    else
        echo -e "${BOLD}Describe what issues you want to create.${NC}"
        echo -e "${DIM}Type or paste your text, then press Ctrl+D when done.${NC}"
        echo ""
        user_text=$(cat)
        if [ -z "$user_text" ]; then
            log_error "No input provided"
            exit 1
        fi
        json=$(create_from_text "$user_text")
    fi

    preview_issues "$json"
    confirm_and_create "$json" "$extra_label"
}

# --- Subcommand routing ---

SUBCOMMAND=""
if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
    SUBCOMMAND="$1"; shift
fi

case "$SUBCOMMAND" in
    "")
        while [[ $# -gt 0 ]]; do
            case $1 in
                --issue)       ISSUE_IDS="$2"; shift 2 ;;
                --max-retries) MAX_RETRIES="$2"; shift 2 ;;
                --max-turns)   MAX_TURNS="$2";   shift 2 ;;
                --label)       ISSUE_FILTERS+=("$2"); shift 2 ;;
                --branch)      BRANCH_OVERRIDE="$2"; shift 2 ;;
                --model)       MODEL_FLAG="--model $2"; shift 2 ;;
                -v|--version)  echo "claude-queue v${VERSION}"; exit 0 ;;
                -h|--help)     show_help; exit 0 ;;
                *)             echo "Unknown option: $1"; exit 1 ;;
            esac
        done
        main
        ;;
    create)
        cmd_create "$@"
        ;;
    *)
        echo "Unknown command: $SUBCOMMAND"
        echo ""
        show_help
        exit 1
        ;;
esac
