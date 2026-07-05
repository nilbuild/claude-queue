# claude-queue

A CLI tool that solves GitHub issues using [Claude Code](https://docs.anthropic.com/en/docs/claude-code). It picks up open issues from your repo, solves them one by one, and opens a pull request with all the fixes. It can also create well-structured GitHub issues from a text description or interactive interview.

The typical workflow is: open issues for whatever you need done, run `claude-queue`, and come back to a pull request with everything solved. I usually do this at night and review the PR in the morning.

Issues don't have to be code changes — they can be investigative tasks like "figure out why the API is slow and document what you find" or "audit the codebase for accessibility issues". Claude will research, document findings, and commit whatever it produces.

## Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`) — installed and configured
- `git` and `jq`

## Install

```bash
npm install -g claude-queue
```

Or run directly:

```bash
npx claude-queue
```

## Usage

### Solving issues

Run from inside any git repository with GitHub issues:

```bash
claude-queue
```

| Flag | Default | Description |
|------|---------|-------------|
| `--issue ID` | all issues | Solve specific issue(s) by ID, URL, or comma-separated IDs |
| `--max-retries N` | `3` | Max retry attempts per issue before marking it failed |
| `--max-turns N` | `50` | Max Claude Code turns per attempt |
| `--label LABEL` | all issues | Only process issues with this label (can be repeated) |
| `--branch BRANCH` | new daily branch | Work on this branch instead of creating a new one per run |
| `--model MODEL` | CLI default | Claude model to use (e.g. `claude-sonnet-4-5-20250929`) |

By default each run creates a fresh `claude-queue/<date>` branch. Pass `--branch` to commit onto an existing branch instead — it's checked out if it exists locally or on the remote, otherwise created from the default branch. If that branch already has an open PR, the run updates it instead of opening a new one.

```bash
# Solve all open issues
claude-queue

# Solve a specific issue by number
claude-queue --issue 42

# Solve a specific issue by URL
claude-queue --issue https://github.com/owner/repo/issues/42

# Solve multiple specific issues
claude-queue --issue 1,2,3

# Only solve issues labeled "bug"
claude-queue --label bug

# Filter by multiple labels
claude-queue --label bug --label urgent

# Commit onto an existing branch instead of a new one
claude-queue --branch my-feature-branch

# Use a specific model with more retries
claude-queue --max-retries 5 --model claude-sonnet-4-5-20250929
```

### Creating issues

Generate GitHub issues from a text description or an interactive interview with Claude.

```bash
claude-queue create "Add dark mode and fix the login bug"
```

There are three ways to provide input:

1. **Inline text** — pass your description as an argument
2. **Stdin** — run `claude-queue create` with no arguments, type or paste your text, then press Ctrl+D
3. **Interactive** — run `claude-queue create -i` and Claude will ask clarifying questions before generating issues

Claude decomposes the input into individual issues with titles, markdown bodies, and labels (reusing existing repo labels where possible). You get a preview before anything is created.

| Flag | Default | Description |
|------|---------|-------------|
| `-i, --interactive` | off | Interview mode — Claude asks clarifying questions first |
| `--label LABEL` | none | Add this label to every created issue |
| `--model MODEL` | CLI default | Claude model to use |

```bash
# Interactive mode
claude-queue create -i

# Add a label to all created issues
claude-queue create --label backlog "Refactor the auth module and add rate limiting"
```

### Create then solve workflow

The `--label` flag on both commands lets you create a pipeline where `create` plans the issues and `claude-queue` solves them:

```bash
# Plan
claude-queue create --label nightshift "Add dark mode and fix the login bug"

# Solve
claude-queue --label nightshift
```

## Configuration

Create a `.claude-queue` file in your repo root to add custom instructions to every issue prompt:

```
Always run `npm test` after making changes.
Use TypeScript strict mode.
Never modify files in the src/legacy/ directory.
```

These instructions are appended to the prompt Claude receives for each issue. Useful for project-specific conventions that aren't in `CLAUDE.md`.

## How It Works

### Preflight

Verifies all dependencies (`gh`, `claude`, `git`, `jq`), checks that `gh` is authenticated, and ensures the working tree is clean.

### Label setup

Creates three labels on the repo (skips if they already exist):

| Label | Meaning |
|-------|---------|
| `claude-queue:in-progress` | Currently being worked on |
| `claude-queue:solved` | Successfully fixed |
| `claude-queue:failed` | Could not be solved after all retries |

### Branching

Creates a branch `claude-queue/YYYY-MM-DD` off your default branch. All fixes go into this one branch. If the branch already exists, a timestamp suffix is added.

### Issue processing

For each open issue (up to 200, oldest first), or for the specific issues passed via `--issue`:

1. **Skip** — issues with any `claude-queue:*` label are skipped (unless targeted via `--issue`). Remove the label to re-process.
2. **Label** — marks the issue `claude-queue:in-progress`.
3. **Solve** — launches Claude Code with a prompt to read the issue, explore the codebase, implement a fix, and run tests.
4. **Evaluate** — if Claude produced file changes, they are committed. If not, the attempt is retried.
5. **Retry** — on failure, the working tree is reset and Claude gets a fresh context. Up to 3 attempts (configurable with `--max-retries`).
6. **Result** — marks the issue `claude-queue:solved` or `claude-queue:failed`.

Issues are solved sequentially so later fixes build on earlier ones within a single branch.

### Review pass

After all issues are processed, Claude does a second pass reviewing all committed changes for bugs, incomplete implementations, and style issues — fixing anything it finds.

### Pull request

Once done, the branch is pushed and a PR is opened with:

- Summary table with solved/failed/skipped counts and run duration
- Tables of solved and failed issues with links
- Collapsible per-issue logs showing Claude's full output

No PR is created if nothing was solved.

### Interruption handling

If interrupted (Ctrl+C, SIGTERM), the script removes the `claude-queue:in-progress` label from the current issue, marks it as failed, and prints where your commits and logs are.

## Logs

Full logs for each run are saved to `/tmp/claude-queue-DATE-TIMESTAMP/`:

```
/tmp/claude-queue-2025-03-15-220530/
├── issue-42.md             # Combined log for issue #42
├── issue-42-attempt-1.log  # Raw Claude output, attempt 1
├── issue-42-attempt-2.log  # Raw Claude output, attempt 2
├── issue-57.md
├── issue-57-attempt-1.log
└── pr-body.md              # Generated PR description
```

## License

MIT
