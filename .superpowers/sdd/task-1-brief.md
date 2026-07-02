# Task 1 — Server crash + capacity DoS fixes (#213, #214)

You are fixing two High-severity, live-reproduced defects in apfel (Swift 6, macOS, on-device LLM CLI + OpenAI-compatible HTTP server). Work in /Users/arthurficial/dev/apfel on branch main. Do NOT push; the controller pushes after review.

## Requirements source (read first)

Read the two issue bodies in `/Users/arthurficial/dev/apfel/.superpowers/sdd/issues-all.md`:
- section "## Issue #213" (concurrency permit + active_requests leak on early-failing streaming requests)
- section "## Issue #214" (AsyncSemaphore.wait(timeout:) aborts the whole process on timeout)

Those bodies contain verified root causes with exact file:line references. Treat them as the spec.

## Order and commits

Fix #214 first (semaphore crash), then #213 (permit leak). One commit per issue:
- `fix(concurrency): structured timeout race in AsyncSemaphore.wait — no more SIGABRT on permit timeout (#214)`
- `fix(server): release concurrency permit + active_requests on early-failing streaming requests (#213)`
(Exact wording yours; keep `fix(...)` prefix + `(#NNN)` suffix.) Commit body: root cause + fix summary. End with:
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## Global constraints (binding)

- TDD red-to-green: write the failing test FIRST, watch it fail for the right reason, then fix, watch it pass. For #214 that is a unit test in Tests/apfelTests/ that forces a wait-timeout and asserts a thrown timeout error (today it crashes the test process — so to observe the red state you may need to run just that test target carefully; a crash IS the red state).
- #213 needs an integration test (Tests/integration/, pytest, model-free if possible: malformed streaming requests return 400 without touching the model) asserting: with the plain server, N malformed `"stream":true` requests leave `/health` `active_requests` at 0 and the server still answers. Follow the existing conftest.py pattern (servers on ports 11434/11435 are started externally by make test — your test must use the existing fixtures, NOT start its own server). Check how existing tests in Tests/integration/security_test.py or openapi_spec_test.py get the base URL.
- Integration tests you cannot run standalone are fine — the controller runs `make test` at the milestone. You CAN run a quick manual verification: build, start `./.build/release/apfel --serve --port 11499 --max-concurrent 2` yourself on a scratch port, curl the malformed streaming request twice, check /health, kill it. Do this and record the result.
- Swift 6 strict concurrency. No `@unchecked Sendable` without a written thread-safety argument. No new build warnings.
- Add a CHANGELOG.md `[Unreleased]` -> `### Fixed` bullet per issue mentioning the issue number.
- No em/en dashes in any text you write; plain hyphens only.
- Do not touch `.version`, `Sources/BuildInfo.swift`, README badge.
- `swift build 2>&1` clean and `swift run apfel-tests` 100% green before each commit.
- IMPORTANT: a `make test` may still be running when you start. Before your first build, run `ps aux | grep "[m]ake test"` and wait (sleep-loop via `for i in ...; do ... done`, or check every 30s) until it is gone, and make sure ports you use for manual verification are scratch ports (11499+), never 11434/11435.

## Key architecture notes

- `AsyncSemaphore` lives in Sources/Retry.swift (actor). The fix per the issue: never resume a CheckedContinuation from an unstructured Task inside the continuation body. Prefer storing the timeout Task handle keyed by waiter id, cancel it in signal(), or restructure as a structured race.
- Stream cleanup: Sources/Server.swift:146-149 keys cleanup on `!result.trace.stream`; the safe fix suggested is making `chatFailure(...)` always set `stream: false` (it never produces SSE) OR an explicit `ownsCleanup` flag on the trace. Pick the one that is cleanest given the actual code — read Handlers.swift `chatFailure` and every early-return path listed in the issue.
- Unit tests are a custom pure-Swift harness (`swift run apfel-tests`, see Tests/apfelTests/main.swift for suite registration). New unit test files must be registered there. Test style: `test("name") { try assertEqual(...) }`; error asserts must inspect the error, not just note a throw.
- Note: `apfel-tests` target only links ApfelCore + ApfelCLI. If AsyncSemaphore (Sources/Retry.swift, root target) is not visible to unit tests, check whether an equivalent seam exists in Sources/Core/Retry.swift; if the actor is genuinely untestable from apfel-tests, move it (or the timeout logic) into ApfelCore (Sources/Core/) preserving public behavior — that is an allowed refactor for testability, note it in the commit body.

## Report

Write your full report to `/Users/arthurficial/dev/apfel/.superpowers/sdd/task-1-report.md`: per issue - root cause confirmed y/n, what you changed (files), tests added (names), red-state evidence (the failing output before the fix), green evidence (test run output after), manual server verification transcript for #213, concerns.
Your final message: status (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED), commit SHAs, one-line test summary, concerns if any.
