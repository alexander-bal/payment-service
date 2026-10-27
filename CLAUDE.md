## Plan before implementation

Before writing code for a non-trivial task, use `AskUserQuestion` to elicit answers a human's broader context provides:

- Ambiguous requests with multiple right answers — "add caching" (memory? disk? per-request? per-session?), "improve performance" (which metric?), "refactor X" (preserve behavior or change it?)
- Acceptance criteria — what state means it's done?
- Out-of-scope — what should NOT change in this task?
- External constraints — downstream consumers, deployment environment, stakeholder expectations not visible in code

Default to asking when the task has plausibly different right answers depending on context outside the codebase. Batch questions into one call when possible so the user answers once and you proceed autonomously. Don't ask things you can determine from reading code. Don't ask trivial confirmations.

Skip only for genuinely unambiguous reversible tasks (typo fixes, renames, well-specified one-liners).

## Plan challenge before implementation

For the same class of non-trivial tasks where `AskUserQuestion` fires (plausibly different right answers, multiple defensible architectures, the fix could plausibly live in 2+ layers): after forming the plan and before writing code, delegate to the `plan-challenger` subagent. Brief with (1) the goal in one line, (2) the proposed approach in one line — what + where, (3) any data, constraints, or prior findings that shaped the choice. The challenger's mandate is to disagree — surface alternatives and hidden assumptions, not ratify. If a substantive alternative comes back, decide whether to revise before implementing. Skip when `AskUserQuestion` is skipped (typo fixes, renames, well-specified one-liners).

## Verify external-effect changes against the real output

When a change's correctness shows up only in an **external system's output** — a metric exposed for scrape, a span/trace exported, a message enqueued, a structured log or event emitted, a webhook payload — verify it by running the code path and observing that system directly (scrape the endpoint, query the trace backend / queue, grep the emitted event). A passing unit test and a clean diff are not sufficient: the real assertion lives outside the process, so in-process tests and diff-reading routinely pass while the wire output is silently wrong — a dropped label, a span that never exports, a metric emitted on only one code path.

A reviewer flag about this kind of output is not dismissible on static grounds ("pre-existing structure," "looks fine") — confirm it against the running system or fix it. Skip when the project's tests already assert on the external output, or when the change can't affect emitted output.

## Comments

In addition to the base "no comments unless WHY is non-obvious" default, suppress these AI-slop patterns:
- No "Important:" / "Note:" prefixes. State the constraint directly or omit.
- No section banners or dividers ("// === Helpers ===", "// --- routes ---"). File structure carries the load.
- No procedural narration ("First, we...", "Now let's...", "Loop through..."). Comments describe state and constraints, not steps.
- No change or history narration ("before X existed", "previously", "used to", "this replaces the old..."). Describe the code as it is now, not how it got here — git blame and the PR own that. Exception: a constraint that outlives the change ("required for v1 clients still in prod").
- TODO/FIXME only when tied to a concrete unfinished item — never as a vague "could be improved."
- Public-API docstrings (JSDoc, PyDoc) are fine even on short bodies. Cap: one line of contract + any non-obvious behavior. No restating the function name in prose.

## Comment review before task completion

Before reporting a coding task done with comment or docstring changes, delegate review to the `comment-reviewer` subagent. Brief with the diff (unified format) only — no description of what changed, your intent, or what the code does. The reviewer's value depends on judging comments with no authorial context.

## Bug, security, and performance review before task completion

After meaningful code changes — anything affecting program behavior or logic — delegate review to the `bug-reviewer`, `security-reviewer`, and `performance-reviewer` subagents (in parallel — independent diff reads) before reporting the task done. Skip only for changes that cannot affect program behavior — docs prose, comments, whitespace, formatting, lockfile version pins. Build / orchestration files (Tiltfile, turbo.json, Makefile, CI workflows, package.json scripts) are code, not config — run the reviewers. Default to running when in doubt. Brief each with the diff (unified format) only — no description of intent or what changed.

## Coverage backfill + test review before task completion

After meaningful code changes, run the `test-cover` skill before the review pass — it backfills tests for the behavior you changed (assertion-based coverage matrix over the diff, pragmatic). Skip per the skill's conditions; default to running when in doubt.

When the change adds or modifies tests — including any `test-cover` just added — delegate review to the `test-reviewer` subagent before reporting the task done — it flags tests that would still pass if the product code broke (vacuous tests) and assertions too loose to catch a realistic regression. Skip when the change touches no tests. Brief with the full task diff (unified format) — product changes and tests together, not a test-only slice — no description of intent or what changed.

## DevOps review before task completion

When the change touches infrastructure-as-code — k8s/Helm manifests, Dockerfiles, Terraform, CI/CD pipelines, deployment or cloud config — delegate review to the `devops-reviewer` subagent before reporting the task done. It carries the operational lens the code reviewers don't (security hardening, drift from a hardened baseline, resource governance, lifecycle/teardown, blast radius) and owns infra/deployment security, where `security-reviewer` stops at the process boundary. A Tiltfile, a CI/CD workflow, a `docker-compose`, a Helm `values.yaml`, kustomize overlays are infra-as-code, not "mere config" — default to running when in doubt. Skip only when the change touches no infra-as-code (pure app logic, docs, tests). Brief with the diff (unified format) only — no description of intent or what changed.

## Git

Don't override git author identity inline. No `git -c user.email=...`, no `git -c user.name=...`, no `--author=...` flags. The global git config is already correct — let it stand.
