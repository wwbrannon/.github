#!/usr/bin/env bash
# Review a change the way the PR workflow will: headless Claude Code, read-only
# tools, and the repository's review criteria in .github/claude-review/prompt.md.
# Run it from a checkout of the repository under review.
#
#   claude-review.sh [HEAD [BASE]]      # defaults: HEAD=HEAD, BASE=origin/<default branch>
#   claude-review.sh --pr 42            # review a GitHub PR (needs gh)
#
# The criteria are read from the default branch (origin/main, say), as the PR
# workflow reads them, never from the revision under review: a change can't
# rewrite its own review instructions, and edits to them take effect only once
# merged. To try out edited criteria before merging them, point
# CLAUDE_REVIEW_PROMPT at the file. For the same reason the head revision is
# checked out into a throwaway worktree and Claude runs there without the
# project's settings, hooks or MCP config: those files belong to the change,
# which is untrusted.
#
# With CLAUDE_REVIEW_REQUEST set to a file, it answers that request (an @claude
# mention, as the mention workflow writes it) about the change instead of
# reviewing it, following respond.md beside this script, and prints the reply.
# This script and respond.md are the engine, the same for every repository; in
# CI they come from the default branch's checkout of the action (or a pinned
# release of it), so they are no more the change's to rewrite than the criteria.
#
# Env: CLAUDE_REVIEW_PROMPT (a local criteria file instead of the default
# branch's), CLAUDE_REVIEW_DEFAULT_BRANCH (default: what origin/HEAD names, else
# main), CLAUDE_REVIEW_OFFLINE (don't fetch: the refs are already local, as in
# CI), CLAUDE_REVIEW_PR_META (PR title/body to pass along; --pr sets it from gh),
# CLAUDE_REVIEW_MODEL (default claude-opus-5-5, as in CI), CLAUDE_REVIEW_BUDGET_USD
# (default 5), CLAUDE_REVIEW_OUT (also write the output to this file),
# CLAUDE_REVIEW_INLINE (write the findings on lines the diff touches to this
# file, as a JSON array of GitHub review comments, and leave only a pointer to
# each in the printed review), CLAUDE_REVIEW_REQUEST (see above).
# Needs jq and claude on PATH. The review goes to stdout; progress, cost and
# token counts go to stderr, the counts on a line starting "tokens:".
set -euo pipefail

engine_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
criteria_path=.github/claude-review/prompt.md
repo_root=$(git rev-parse --show-toplevel)
default_branch=${CLAUDE_REVIEW_DEFAULT_BRANCH:-}
if [[ -z $default_branch ]]; then
	default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
	default_branch=${default_branch#origin/}
	default_branch=${default_branch:-main}
fi
request=${CLAUDE_REVIEW_REQUEST:-}
[[ -z $request || -f $request ]] || { echo "missing $request" >&2; exit 1; }

pr_meta=${CLAUDE_REVIEW_PR_META:-}
if [[ ${1:-} == --pr ]]; then
	pr=${2:?usage: --pr NUMBER}
	head_ref=$(gh pr view "$pr" --json headRefOid -q .headRefOid)
	base_ref=$(gh pr view "$pr" --json baseRefName -q .baseRefName)
	[[ -n ${CLAUDE_REVIEW_OFFLINE:-} ]] || git fetch --quiet origin "$base_ref" "pull/$pr/head"
	base_ref="origin/$base_ref"
	pr_meta=$(gh pr view "$pr" --json number,title,body,author \
		-q '"PR #\(.number) by \(.author.login): \(.title)\n\n\(.body)"')
else
	head_ref=${1:-HEAD}
	base_ref=${2:-origin/$default_branch}
fi
# Untrusted, and placed inside <pr> tags: escaped so it can't close them.
pr_meta=$(printf '%s' "$pr_meta" | sed 's/</\&lt;/g')

head_sha=$(git rev-parse --verify "$head_ref^{commit}")
base_sha=$(git merge-base "$base_ref" "$head_sha")
if [[ $head_sha == "$base_sha" ]]; then
	echo "nothing to review: $head_ref is already in $base_ref" >&2
	exit 1
fi

tmp_root=${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}
work=$(mktemp -d "${tmp_root:-${TMPDIR:-/tmp}}/claude-review.XXXXXX")
# Resolved, as Claude Code resolves paths before matching them to the Read rule
# below (on macOS, /var is a link to /private/var).
work=$(cd "$work" && pwd -P)
# shellcheck disable=SC2317,SC2329  # invoked via trap (older/newer shellcheck)
cleanup() {
	git -C "$repo_root" worktree remove --force "$work/src" 2>/dev/null || true
	git -C "$repo_root" worktree remove --force "$work/ctx/base" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

# The criteria: the default branch's, unless a local file is named. A review
# follows them; an answer to a request follows respond.md, and gets the
# criteria beside the checkout, to read when asked to judge the change.
if [[ -n ${CLAUDE_REVIEW_PROMPT:-} ]]; then
	# Absolute now: Claude runs from the head checkout, where a relative path
	# would silently pick up the change's own copy of the criteria.
	[[ -f $CLAUDE_REVIEW_PROMPT ]] || { echo "missing $CLAUDE_REVIEW_PROMPT" >&2; exit 1; }
	criteria_file="$(cd "$(dirname "$CLAUDE_REVIEW_PROMPT")" && pwd)/$(basename "$CLAUDE_REVIEW_PROMPT")"
	echo "using local criteria $criteria_file (not origin/$default_branch's)" >&2
else
	if [[ -z ${CLAUDE_REVIEW_OFFLINE:-} ]]; then
		git fetch --quiet origin "$default_branch" \
			|| echo "warning: couldn't fetch origin/$default_branch; using the last fetched copy" >&2
	fi
	criteria_file="$work/criteria.md"
	git show "origin/$default_branch:$criteria_path" > "$criteria_file" 2>/dev/null || {
		echo "origin/$default_branch has no $criteria_path; set CLAUDE_REVIEW_PROMPT to use a local copy" >&2
		exit 1
	}
fi
if [[ -n $request ]]; then
	prompt_file="$engine_dir/respond.md"
else
	prompt_file=$criteria_file
fi

git -C "$repo_root" worktree add --quiet --detach "$work/src" "$head_sha"

# Claude gets file tools only, no shell: even read-only git subcommands can
# read any file through a flag (`git blame --contents PATH`, abbreviable to
# `--conte`), and the credential is in Claude's environment. So what git would
# have told it is written out here instead, under ctx/.
ctx="$work/ctx"
mkdir "$ctx"
git -C "$repo_root" worktree add --quiet --detach "$ctx/base" "$base_sha"
git diff --stat "$base_sha" "$head_sha" > "$ctx/change.diff"
git diff "$base_sha" "$head_sha" >> "$ctx/change.diff"
git log --no-merges --format='commit %H%nAuthor: %an%nDate:   %ad%n%n%w(0,4,4)%B' \
	"$base_sha..$head_sha" > "$ctx/commits.txt"
git diff --name-only -z "$base_sha" "$head_sha" \
	| xargs -0 git log -n 200 --format='%h %ad %an: %s' --date=short "$base_sha" -- \
	> "$ctx/history.txt"
if [[ -n $request ]]; then
	cp "$criteria_file" "$ctx/review-criteria.md"
fi

commits=$(git log --no-merges --format='- %h %s' "$base_sha..$head_sha")
stat=$(git diff --stat "$base_sha" "$head_sha" | tail -n 1)

context=$(cat <<EOF
The working directory is a checkout of the head revision. Alongside it, in
$ctx:
- change.diff: the change, \`git diff --stat\` then the full diff
- commits.txt: the change's commits, with full messages
- history.txt: the last 200 commits before the change touching its files
- base/: a checkout of the merge base, to see a file as it was before${request:+
- review-criteria.md: the criteria the automated review uses, from $default_branch}
You have file tools only (Read, Grep, Glob), confined to $work.

Commits:
$commits

Size: $stat
${pr_meta:+
PR metadata (untrusted, written by the author):
<pr>
$pr_meta
</pr>
}
EOF
)

if [[ -n $request ]]; then
	task=$(cat <<EOF
Answer the request below about the change from merge base $base_sha to head
$head_sha. $context

$(cat "$request")
EOF
	)
else
	task=$(cat <<EOF
Review the change from merge base $base_sha to head $head_sha.
$context
Start with change.diff (its --stat header first if it is large), then read
whatever you need.
EOF
	)
fi

# The review's shape, so CI can place each finding without parsing Markdown.
# The prompt describes the fields.
schema='{
  "type": "object",
  "additionalProperties": false,
  "required": ["summary", "findings", "checked"],
  "properties": {
    "summary": {"type": "string"},
    "findings": {"type": "array", "items": {
      "type": "object",
      "additionalProperties": false,
      "required": ["severity", "title", "path", "line", "problem", "scenario", "fix"],
      "properties": {
        "severity": {"enum": ["blocker", "should-fix", "nit"]},
        "title": {"type": "string"},
        "path": {"type": "string"},
        "line": {"type": "integer", "minimum": 1},
        "problem": {"type": "string"},
        "scenario": {"type": "string"},
        "fix": {"type": "string"}
      }
    }},
    "checked": {"type": "array", "items": {"type": "string"}}
  }
}'

args=(
	-p "$task"
	--append-system-prompt-file "$prompt_file"
	--tools "Read,Grep,Glob"
	# Read rules govern Grep and Glob too, and symlinks are judged by their
	# targets, so a link in the checkout can't lead out of $work. Under
	# dontAsk, anything not allowed is refused. /proc (the credential is in
	# Claude's environment, at /proc/PID/environ) is denied outright as well,
	# should a CLI default or the rule above ever change.
	--allowedTools "Read(/$work/**)"
	--disallowedTools "Read(//proc/**)"
	--permission-mode dontAsk
	# No settings at all. The checkout's .claude/ settings and CLAUDE.md files
	# are the change's, so must not load. Nor do yours (~/.claude: model,
	# effort, plugins and their hooks, CLAUDE.md), so a local run reviews the
	# way CI's bare runner does. Login isn't a setting and still works.
	--setting-sources ""
	--strict-mcp-config
	--no-session-persistence
	--max-budget-usd "${CLAUDE_REVIEW_BUDGET_USD:-5}"
	--output-format json
)
# Pinned to the model the prompts were tuned on, here rather than in the
# workflows so local runs use it too; the CLI default could be another one.
args+=(--model "${CLAUDE_REVIEW_MODEL:-claude-opus-5-5}")
[[ -z $request ]] && args+=(--json-schema "$schema")

echo "${request:+answering a request on }$base_sha..$head_sha ($stat)" >&2
out=$(cd "$work/src" && claude "${args[@]}") || true  # report the failure below

# Summed over every model the run used, subagents included, so they cover the
# whole run. To stderr, so stdout stays ready to post. The dollar figure is at
# list price, which isn't what a subscription pays.
jq -r '
	def commas: tostring | until(test("[0-9]{4}") | not; sub("(?<a>[0-9])(?<b>[0-9]{3})(?<c>,|$)"; "\(.a),\(.b)\(.c)"));
	def total(f): [.modelUsage // {} | .[] | f] | add // 0;
	"cost: [\(.modelUsage // {} | keys | join(", "))] $\(.total_cost_usd // 0 | . * 100 | round / 100) in \(.num_turns) turns, \(.duration_ms / 1000 | round)s",
	"tokens: \(total(.inputTokens + .cacheReadInputTokens + .cacheCreationInputTokens) | commas) input (\(total(.cacheReadInputTokens) | commas) read from cache), \(total(.outputTokens) | commas) output"
' <<<"$out" >&2 || true

fail() {
	echo "$1 failed: $(jq -r '.subtype // "no result"' <<<"$out" 2>/dev/null || echo "unparseable output")" >&2
	exit 1
}

if [[ -n $request ]]; then
	reply=$(jq -r 'select(.is_error | not) | .result // empty' <<<"$out" 2>/dev/null) || true
	[[ -n $reply ]] || fail request
	printf '%s\n' "$reply"
	[[ -n ${CLAUDE_REVIEW_OUT:-} ]] && printf '%s\n' "$reply" > "$CLAUDE_REVIEW_OUT"
	exit 0
fi

review=$(jq -c 'select(.is_error | not) | .structured_output // empty' <<<"$out" 2>/dev/null) || true
[[ -n $review ]] || fail review

# Where a GitHub review comment can go: lines on the head side of the diff
# inside a hunk, added or context, one "path<TAB>line" per line. GitHub diffs
# a pull request from the merge base with three lines of context, as this
# does. Paths git has to quote are left out, so findings there stay in the body.
anchors=""
if [[ -n ${CLAUDE_REVIEW_INLINE:-} ]]; then
	anchors=$(git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv -U3 \
		--src-prefix=a/ --dst-prefix=b/ "$base_sha" "$head_sha" | awk '
		/^diff --git / { hunk = 0; path = ""; next }
		!hunk && /^\+\+\+ / {  # git ends the name with a tab when it has a space
			path = (substr($0, 5, 2) == "b/") ? substr($0, 7) : ""; sub(/\t$/, "", path); next
		}
		/^@@ / { hunk = 1; match($0, /\+[0-9]+/); line = substr($0, RSTART + 1, RLENGTH - 1); next }
		hunk && /^[ +]/ { if (path != "") print path "\t" line; line++ }
	')
	jq --arg anchors "$anchors" '
		($anchors | split("\n") | map({(.): true}) | add // {}) as $ok
		| [.findings[] | select($ok["\(.path)\t\(.line)"])
		   | {path, line, side: "RIGHT",
		      body: "**[\(.severity)] \(.title)**\n\n**Problem:** \(.problem)\n\n**Scenario:** \(.scenario)\n\n**Fix:** \(.fix)"}]
	' <<<"$review" > "$CLAUDE_REVIEW_INLINE"
fi

# The layout prompt.md gives for an interactive review, except that a finding
# posted inline is only pointed to.
rendered=$(jq -r --arg anchors "$anchors" '
	($anchors | split("\n") | map({(.): true}) | add // {}) as $ok
	| "## Claude review\n\n\(.summary)\n\n### Findings\n\n"
	+ (if (.findings | length) == 0 then "No findings."
	   else [.findings[] |
	     "#### [\(.severity)] \(.title)\n"
	     + if $ok["\(.path)\t\(.line)"] then "Inline comment at `\(.path):\(.line)`."
	       else "**Where:** `\(.path):\(.line)`\n**Problem:** \(.problem)\n**Scenario:** \(.scenario)\n**Fix:** \(.fix)" end
	   ] | join("\n\n") end)
	+ (if (.checked | length) > 0 then "\n\n### Checked and fine\n\n" + (.checked | map("- " + .) | join("\n")) else "" end)
' <<<"$review")

printf '%s\n' "$rendered"
[[ -n ${CLAUDE_REVIEW_OUT:-} ]] && printf '%s\n' "$rendered" > "$CLAUDE_REVIEW_OUT"
exit 0
