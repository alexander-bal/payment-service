---
name: test-cover
description: >
  Backfill test coverage for the behavior you changed in the current task. Builds an
  assertion-based coverage matrix over the diff and writes pragmatic tests for the
  uncovered changes — skipping what needs heavy scaffolding or would be flaky. Use at
  end of task after code changes. Not for pre-existing untouched code, and not the
  pre-fix pinning in bug-fix.
---

# Cover changed behavior

After a task changes program behavior, cover the behavior you changed with tests before reporting done. The scope is the task's diff — what you added or changed — not pre-existing untested code.

## 1. Scope the change

Take the task's diff (branch commits + uncommitted changes). List the caller-observable behaviors you added or changed — return values, mutations, side effects, raised errors, new branches. That list is the surface to cover.

## 2. Coverage matrix (assertion-based)

For each changed behavior, ask whether a test **asserts** it — read the test to confirm an assertion guards the output, not just that a line executes (a coverage tool can hint at never-executed lines, but execution is not assertion). Emit:

| Changed behavior | Asserted by a test? | Test |
|---|---|---|

Behavior you already covered this task — a bug test or pins from `bug-fix`, a TDD test written alongside the code — is asserted; it needs nothing more.

## 3. Write the missing tests — pragmatically

For each unasserted behavior, add a test that asserts its observable output. Match the project's existing test framework and patterns; don't stand up new infrastructure. Be pragmatic — skip, don't force:

- Behavior that needs heavy scaffolding to reach (DB, network, external services, elaborate mocks) — the setup cost outweighs the coverage.
- Behavior whose test would be flaky (timing, ordering, wall-clock, network, other non-determinism).

Assert real values, not mere execution — a test that only checks "runs without throwing" catches nothing. State what you skipped and why; no silent gaps.

## 4. Verify

Run the new tests — they must pass. Run related tests — they must still pass.

## Skip the whole step when

- The change carries no program behavior: docs, comments, formatting, config, pure moves/renames, dependency bumps, reverts, generated/codegen output.
- The changed behavior is already covered by tests you wrote this task (e.g. a bug fix via `bug-fix` already covers its change surface).
- The project has no test setup — don't build test infrastructure to satisfy this; say so and stop.

## Output

Report compactly: the matrix, the tests you added, and what you deliberately skipped with the reason.
