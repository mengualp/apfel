# Global constraints for all audit-fix tasks (binding)

Repo: /Users/arthurficial/dev/apfel, branch main. Do NOT push; the controller pushes after review.
Requirements live in `.superpowers/sdd/issues-all.md` - read the "## Issue #NNN" sections named in your dispatch. They contain verified root causes with exact file:line refs; treat them as the spec.

- TDD red-to-green: failing test FIRST (watch it fail for the right reason), then minimal fix, then green. No production code without a failing test.
- One commit per issue: `fix|feat|test|ci|docs(area): summary (#NNN)`. Body = root cause + fix. End with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Each user-visible fix adds a CHANGELOG.md `[Unreleased]` bullet (proper Added/Fixed/Changed subsection) naming the issue.
- Swift 6 strict concurrency; no `@unchecked Sendable` without written proof; `swift build 2>&1` must show zero warnings.
- Unit test runner: `swift run apfel-tests` (custom harness; register new files in Tests/apfelTests/main.swift). Must be 100% green before each commit. Error-assert style: catch the typed error and assert on its message/fields - never bare "it threw".
- Layering: ApfelCore (Sources/Core/) stays FoundationModels-free and Hummingbird-free. Put pure logic there so apfel-tests can cover it. apfel-tests links only ApfelCore + ApfelCLI - root-target files (Sources/*.swift) are NOT unit-testable; testable logic must live in Core.
- Integration tests (pytest, Tests/integration/): follow conftest.py fixture patterns; servers on 11434/11435 are started externally - never start servers on those ports yourself. For manual live verification use scratch ports 11499+. Model-dependent integration tests are written but run by the controller at milestones; you run model-free ones you add.
- Before your first build: check `ps aux | grep -E "[m]ake (test|preflight)"` is empty; if not, wait until it finishes.
- No em dashes or en dashes in anything you write; plain hyphens only.
- Never touch `.version`, `Sources/BuildInfo.swift`, README version badge.
- Flags/env-vars/exit-codes changes must update `--help` (Sources/CLI.swift printUsage) AND the man page source together (test_man_page.py enforces bidirectional coverage).
- Match existing code style; comments only for non-obvious constraints.
- Report: write the full report to the report path named in your dispatch (per issue: root cause confirmed y/n, files changed, tests added, red evidence, green evidence, concerns). Final message: ONLY status (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED), commit SHAs, one-line test summary, concerns.
