---
name: bug-fix
description: >
  Test-driven workflow for fixing a specific bug. Use when the user reports a bug,
  error, test failure, or regression and asks you to fix it. Not for new features,
  refactors, or speculative changes.
---

# Bug Fix

When fixing a specific bug, follow this workflow.

## 1. Reproduce

Confirm the bug exists. Capture *how* you reproduced it — the steps, the failing command, the browser action — concretely enough to re-run in step 5. If you cannot reproduce, STOP and ask for exact reproduction steps. Do not speculate-fix.

## 2. Investigate + write a failing test (RED)

Read the code path to determine root cause — use `grep`, file reads, tests, or temporary instrumentation. Do not guess. State the root cause in one sentence before writing the test: "Root cause: <one-line>." Then name the change surface — the specific files/functions/branches the fix will touch; step 3 builds on it.

Write a test that captures the *correct* behavior the fix should produce. Run it — it must fail, and fail for the right reason (because of the bug, not because of a typo in the test or unrelated infrastructure).

If you cannot write a meaningful failing test, you do not understand the bug well enough yet — keep investigating. A test that passes immediately is not capturing the bug; a test that fails for unrelated reasons is not capturing it either.

## 3. Pin the change surface (PINS)

Build a regression safety net over the change surface from step 2 — the functions/branches the fix will touch. For each behavior of that surface a **caller depends on** (return value, mutation, side effect, raised error), ask whether an existing test **asserts** it — read the test to confirm an assertion guards it; a coverage tool can hint at never-executed lines, but execution is not assertion. Emit the matrix:

| Caller-observable behavior | Asserted by a test? | Test |
|---|---|---|

For each unasserted behavior this fix could change, write a pin — a characterization test that asserts its *current correct* behavior (what the code does today, which the fix must preserve). Run it — it must PASS now; the step 2 bug test, by contrast, must fail. Pins stay green through the fix — that is how you prove the fix changed only the buggy behavior.

Bound to blast radius: only behaviors a caller depends on and this fix could realistically break. Don't pin already-asserted behavior; don't pin the whole module because you read it. If a row's current behavior *is* the bug, it belongs to the step 2 bug test, not a pin.

Skip only when the change surface is a single trivial line with no branching (typo, constant, rename) — say you skipped, and why.

## 4. Fix (GREEN)

Make the smallest change that turns the failing test green. The fix should land at the layer where the bug originates, not where the symptom surfaces.

## 5. Verify (both axes)

After implementing:
- Run the new test — it must pass
- Run the step 3 pins — they must still pass; the fix changed only the buggy behavior
- Re-do step 1's reproduction method — the bug must be gone. For UI changes, this means re-running the same browser QA you used to confirm the bug; delegate to your project's QA agent if you have one
- Run related tests — they must still pass

Remove any temporary instrumentation before declaring done. Do not claim the bug is fixed without all four confirmations.

## Anti-patterns (do not do these)

- **Skipping the failing test**: writing the fix before the test that captures the bug
- **Test that passes immediately**: the test isn't actually exercising the buggy path
- **Symptom patching**: wrapping the failure in try/catch or adding a defensive null check at the surface layer instead of fixing the root cause
- **Speculative fixes**: "maybe this works" without a verified hypothesis
- **Reverting without understanding**: rolling back a recent commit just because the bug appeared after it
- **Logging instead of fixing**: adding `console.log` or `print` as a "fix"
- **Shotgun defensive code**: adding null checks everywhere as cover
- **Over-fix**: changing code adjacent to the bug because you happened to read it — even if the change is a genuine improvement, do it in a separate commit, not bundled with the fix
- **Pinning the bug**: a pin that locks in the current *broken* behavior — pins protect behavior that is correct today and must stay; the broken behavior belongs to the bug test
- **Over-pinning**: pins for branches outside the change surface, or for behavior no caller depends on — matrix rows are bounded by blast radius, not by everything you happened to read

## Output

Once verified, summarize concisely:

```
Root cause: <one-line>
Test: <which test now covers this bug>
Fix: <one-line description of the change>
Verification: <new test passes + how you re-confirmed the original reproduction is gone>
```

Keep it compact — the diff is the change, the summary is the context.
