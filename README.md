# Shared workflows and actions

The CI pieces my repositories have in common: a security check, Claude pull
request reviews and @claude answers, and the actions they are built from.
Everything is pinned (third-party actions by commit SHA, tools by image digest
or checksum, Claude Code by lockfile), and Dependabot keeps it current here, in
one place, with a week's cooldown on every release.

## Reusable workflows

Call them with a full commit SHA of this repository, as for any third-party
action. Each workflow checks out this repository **at the commit it was called
at** (`job.workflow_repository`, `job.workflow_sha`) and runs its actions from
there, so that one SHA fixes the workflow and every action it uses together.

| Workflow | Does |
|---|---|
| `reusable-security.yml` | gitleaks over the whole history, and actionlint with shellcheck over every `run:` block. Both use shared rules with no exemptions from the checkout, so a pull request can't switch off the check that gates it: a `.gitleaks.toml`, `.gitleaksignore`, `.github/actionlint.y*ml` or `.shellcheckrc` fails the job |
| `reusable-claude-review.yml` | reviews each pull request with headless, read-only Claude Code and posts a pull request review, findings inline where the diff allows |
| `reusable-claude-mention.yml` | answers `@claude` in a pull request's discussion, from someone with write access, with the same read-only tools |

### Security

```yaml
# .github/workflows/security.yml
name: Security
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  security:
    uses: wwbrannon/.github/.github/workflows/reusable-security.yml@<sha> # <tag>
```

The checks report as `security / gitleaks` and `security / actionlint`; those
are the names to require in a branch ruleset.

### Claude review and mentions

The review criteria are the calling repository's own, in
`.github/claude-review/prompt.md`, read from its default branch, never from the
change under review. The workflows here are the engine.

```yaml
# .github/workflows/claude-review.yml
name: Claude review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
permissions:
  contents: read
concurrency:
  group: claude-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  review:
    if: vars.CLAUDE_REVIEW_ENABLED == 'true'
    permissions:
      contents: read
      pull-requests: write
    uses: wwbrannon/.github/.github/workflows/reusable-claude-review.yml@<sha> # <tag>
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

```yaml
# .github/workflows/claude-mention.yml
name: Claude mention
on:
  issue_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  pull_request_review_comment:
    types: [created]
permissions:
  contents: read
# No concurrency group: it would drop mentions made in quick succession.
jobs:
  respond:
    if: vars.CLAUDE_REVIEW_ENABLED == 'true'
    permissions:
      contents: read
      pull-requests: write
    uses: wwbrannon/.github/.github/workflows/reusable-claude-mention.yml@<sha> # <tag>
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Both take optional inputs `budget-usd` (default `"5"`, a runaway guard) and
`model` (default: the model the prompts were tuned on). To switch them on:

```sh
claude setup-token                 # a subscription token; or use a Console API key
gh secret set CLAUDE_CODE_OAUTH_TOKEN   # or: gh secret set ANTHROPIC_API_KEY
gh variable set CLAUDE_REVIEW_ENABLED --body true
```

If both secrets are set, the subscription token is used. The secrets are named
in the caller rather than passed with `secrets: inherit`, so the workflows get
those two and nothing else.

Pull requests from forks, drafts and Dependabot are skipped. On a fork's pull
request, an @claude in a plain comment gets a refusal (the job holds the
secrets); in a review or an inline comment it is skipped without a reply, since
those events run with a read-only token that can't post one.

## Actions

Composite actions under `.github/actions/`, usable on their own as
`wwbrannon/.github/.github/actions/<name>@<sha>`. None of them uses another with
`uses: ./` or reads the caller's files unless an input names them, so each
works the same from any repository.

| Action | Does |
|---|---|
| `install-tools` | copies CI tools out of their official images, pinned by tag and digest in its `Dockerfile` (or a `pins:` file of the caller's, same format), verifying the vendor's signature where there is one. Never runs the image. |
| `install-cosign` | a checksummed cosign release binary, amd64 or arm64; the one tool not pinned as an image, since it checks those images' signatures |
| `install-claude-code` | the Claude Code CLI at the version and integrity hash in its lockfile |
| `claude-review` | runs `claude-review.sh`: a review, or an answer to a request, with Claude limited to reading a throwaway checkout |
| `free-disk-space` | deletes the preinstalled toolchains and images an image build doesn't need |

`claude-review.sh` also runs locally, from a checkout of the repository to
review: `bash path/to/.github/actions/claude-review/claude-review.sh --pr 42`.

## Updating

Dependabot proposes updates to the actions, the tool images and Claude Code.
cosign is upgraded by hand: change the three defaults in
`.github/actions/install-cosign/install-cosign.sh`.

Then tag a release and move callers to its SHA. A caller's own Dependabot
follows the tags.

`python3 tests/check.py` checks the rules above: pins in one place,
third-party actions pinned by SHA, no `uses: ./` between actions, and reusable
workflows that run their actions only from their own checkout.
