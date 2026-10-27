---
name: write-spec
description: >
  Write a spec — a short design/requirements document for a piece of work, saved
  as a file. Use whenever asked to write a spec, spec out a feature, draft a
  specification, or capture a plan as a spec document.
---

# Write a Spec

Work in three phases — don't skip ahead to writing.

## 1. Analyze

- Read existing specs in `docs/specs/` to learn the repo's format and conventions (structure,
  sections, naming, tone) and to find any prior specs that overlap this work.
- Read the relevant parts of the current codebase so the spec reflects what's actually
  there — constraints, existing patterns, what already exists vs. what's new.
- From all of that, form a view of what's being asked and where it's underspecified,
  ambiguous, or in tension with the code or existing specs.

## 2. Clarify (challenge the user)

Use the `AskUserQuestion` tool to resolve the gaps from phase 1. Don't just collect
answers — challenge. Surface alternatives the user hasn't considered, push back on
underspecified or questionable choices, and name assumptions that could be wrong.
Loop until nothing material is unresolved. Batch related questions per call.

## 3. Write

- Pick a `<slug>` matching the repo's existing file-naming convention. Target file:
  `<specs-repo>/<slug>.md` (flat — no subdirectories). If it already exists, confirm
  before overwriting.
- Write the spec in the repo's established format — don't impose your own template.
