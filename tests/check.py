#!/usr/bin/env python3
"""The rules that keep these actions and workflows usable from other repositories.

    python3 tests/check.py      # from the repository root

- Every tool pin is an image by tag and digest, named once, with a binary path,
  and used by a workflow here.
- No tool is pinned anywhere else (cosign excepted: it checks the pins'
  signatures, so it can't be one of them).
- Every third-party action is pinned to a full commit SHA.
- An action reaches a sibling only through $GITHUB_ACTION_PATH/../NAME, never
  `uses: ./` (resolved against the caller's checkout, not this repository).
- A reusable workflow runs shared actions only from .shared/, its own checkout
  of this repository at its own commit, and checks that checkout out first.
"""
import os
import re
import sys

ACTIONS = ".github/actions"
WORKFLOWS = ".github/workflows"
PINS = f"{ACTIONS}/install-tools/Dockerfile"
COSIGN = f"{ACTIONS}/install-cosign/"

failed = 0


def check(name, ok, detail=""):
    global failed
    print(f"    {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failed += 1
        if detail:
            print(f"         {detail}")


def code_lines(text):
    """(line number, line) for each line that isn't a comment."""
    for n, line in enumerate(text.splitlines(), 1):
        if not line.lstrip().startswith("#"):
            yield n, line


actions = sorted(d for d in os.listdir(ACTIONS) if os.path.isfile(f"{ACTIONS}/{d}/action.yml"))
action_files = sorted(f"{ACTIONS}/{d}/{f}" for d in actions for f in os.listdir(f"{ACTIONS}/{d}")
                      if f.endswith((".yml", ".sh")))
workflow_files = sorted(f"{WORKFLOWS}/{f}" for f in os.listdir(WORKFLOWS) if f.endswith(".yml"))
reusable = [f for f in workflow_files if os.path.basename(f).startswith("reusable-")]
text = {f: open(f).read() for f in action_files + workflow_files}

print("  tool pins")
pins, bad = {}, []
path = None
for line in open(PINS):
    line = line.rstrip("\n")
    if line.startswith("# path: "):
        path = line.split()[2]
    elif line.startswith("FROM "):
        m = re.fullmatch(r"FROM \S+:[^@\s]+@sha256:[0-9a-f]{64} AS ([a-z0-9-]+)", line)
        if not m:
            bad.append(line)
        elif m.group(1) in pins:
            bad.append(f"{line} (stage named twice)")
        elif not path:
            bad.append(f"{line} (no # path: above it)")
        else:
            pins[m.group(1)] = path
        path = None
check("every pin is an image by tag and digest, named once, with a path", not bad, "; ".join(bad))

installed = set()
for f in workflow_files:
    for m in re.finditer(r"uses: \./(?:\.shared/)?\.github/actions/install-tools\n(?:.*\n)*?\s+tools: (.+)", text[f]):
        installed.update(m.group(1).split())
check("every tool installed is pinned", installed <= set(pins), ", ".join(sorted(installed - set(pins))))
check("every pin is installed somewhere", set(pins) <= installed, ", ".join(sorted(set(pins) - installed)))

stray = []
for f in action_files + workflow_files:
    if f.startswith(COSIGN):
        continue
    for n, line in code_lines(text[f]):
        if re.search(r"@sha256:[0-9a-f]{64}|releases/download/|sha256sum -c|_SHA256:|_VERSION:", line):
            stray.append(f"{f}:{n}")
check("no tool is pinned outside the pins file (cosign excepted)", not stray, "; ".join(stray))

print("  action references")
# The one exception: this repository's own caller workflows call its reusable
# workflows at @main, so a pull request is reviewed by main's engine rather
# than its own. Only there: a reusable workflow or an action gets this
# repository from .shared/, never by a remote reference.
SELF = "wwbrannon/.github/"
unpinned, self_ref = [], []
for f in action_files + workflow_files:
    for n, line in code_lines(text[f]):
        m = re.search(r"uses: ([^\s#]+)", line)
        if not m or m.group(1).startswith("./"):
            continue
        if m.group(1).startswith(SELF):
            if f in reusable or f in action_files or not re.fullmatch(
                    re.escape(SELF) + r"\.github/workflows/reusable-[\w-]+\.yml@main", m.group(1)):
                self_ref.append(f"{f}:{n} {m.group(1)}")
        elif not re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", m.group(1)):
            unpinned.append(f"{f}:{n} {m.group(1)}")
check("every third-party action is pinned to a commit SHA", not unpinned, "; ".join(unpinned))
check("this repository refers to itself only from its callers, to a reusable workflow at @main",
      not self_ref, "; ".join(self_ref))

local_in_action, missing_sibling = [], []
for f in action_files:
    for n, line in code_lines(text[f]):
        if re.search(r"uses: \./", line):
            local_in_action.append(f"{f}:{n}")
        for sib in re.findall(r"\$\{?GITHUB_ACTION_PATH\}?/\.\./([\w-]+)", line):
            if sib not in actions:
                missing_sibling.append(f"{f}:{n} ../{sib}")
check("no action uses another with `uses: ./`", not local_in_action, "; ".join(local_in_action))
check("every sibling an action runs exists", not missing_sibling, "; ".join(missing_sibling))

print("  reusable workflows")
wrong_local, unchecked = [], []
for f in reusable:
    for n, line in code_lines(text[f]):
        m = re.search(r"uses: (\./\S+)", line)
        if m and not re.fullmatch(r"\./\.shared/\.github/actions/([\w-]+)", m.group(1)):
            wrong_local.append(f"{f}:{n} {m.group(1)}")
        elif m and m.group(1).rsplit("/", 1)[1] not in actions:
            wrong_local.append(f"{f}:{n} {m.group(1)} (no such action)")
    jobs = re.split(r"\n  ([a-z0-9_-]+):\n", text[f].split("\njobs:\n", 1)[-1])
    for name, body in zip(jobs[1::2], jobs[2::2]):
        first = body.find("uses: ./.shared/")
        shared = re.search(r"repository: \$\{\{ job\.workflow_repository \}\}\n\s+ref: \$\{\{ job\.workflow_sha \}\}\n\s+path: \.shared\n", body)
        guard = "WORKFLOW_SHA: ${{ job.workflow_sha }}" in body
        if first >= 0 and not (shared and guard and shared.start() < first):
            unchecked.append(f"{f}: {name}")
check("reusable workflows run shared actions only from .shared/", not wrong_local, "; ".join(wrong_local))
check("each job checks out .shared/ at its own commit, guarded, before using it", not unchecked, "; ".join(unchecked))
no_main = [f"{f}:{n}" for f in reusable for n, line in code_lines(text[f])
           if re.search(r"\bref: main\b|origin/main\b", line)]
check("no reusable workflow assumes the default branch is main", not no_main, "; ".join(no_main))

print(f"\n  {len(action_files) + len(workflow_files)} files, {failed} failed")
sys.exit(1 if failed else 0)
