# Task 1 Report - Server crash + capacity DoS fixes (#213, #214)

Branch: main (not pushed). Commits:
- `cc02d5f` fix(concurrency): semaphore wait timeout no longer aborts the process with SIGABRT (#214)
- `5310075` fix(server): release concurrency permit + active_requests on early-failing streaming requests (#213)

## Issue #214 - AsyncSemaphore.wait(timeout:) SIGABRT

**Root cause confirmed:** YES, with one refinement. The issue's stated cause (unstructured timeout Task spawned inside the withCheckedThrowingContinuation body) is real but incomplete. I hoisted the Task out of the continuation body and stored/cancelled it per issue fix option 2 - the process STILL crashed with the identical signature. The empirically confirmed trigger is the generic clock-based `Task.sleep(for:)` inside that isolation-inheriting child task under the server executor: the crash report's faulting frame is `swift_task_dealloc` INSIDE `Task.sleep(for:tolerance:clock:)` itself. Switching the child to `Task.sleep(nanoseconds:)` eliminates the crash deterministically. A standalone repro (same actor code, swiftc -O -swift-version 6 -wmo) does NOT crash; the Hummingbird/NIO server environment is required, pointing at a Swift runtime/executor interaction rather than pure library-code misuse.

**What changed (files):**
- `Sources/Core/Concurrency/AsyncSemaphore.swift` (new): AsyncSemaphore + SemaphoreTimeoutError moved from `Sources/Retry.swift` (root target) into ApfelCore, made public (additive API), so apfel-tests can exercise them. Allowed testability refactor per brief; noted in commit body.
  - Timeout task sleeps via `Task.sleep(nanoseconds:)` (the fix that stops the SIGABRT); overflow-saturating Duration-to-nanoseconds helper.
  - Timeout task created outside the continuation body, stored on the actor keyed by waiter UUID, cancelled by `signal()` on permit handoff (no orphan 30s timers; issue fix option 2, kept as hygiene even though it alone did not stop the crash).
  - Doc comment warns future editors not to switch back to `Task.sleep(for:)`.
- `Sources/Retry.swift`: deleted (fully superseded).
- `Tests/apfelTests/AsyncSemaphoreTests.swift` (new) + registration in `Tests/apfelTests/main.swift`.

**Tests added (names):** suite `AsyncSemaphoreTests`:
- "wait succeeds immediately when a permit is available"
- "wait throws SemaphoreTimeoutError on genuine timeout (no crash)" (inspects errorDescription)
- "signal releases a queued waiter before its timeout"
- "permit accounting stays correct after a timeout"
- "many concurrent waiters all time out cleanly" (10 concurrent waiters, all must throw SemaphoreTimeoutError)

**Red-state evidence:** The unit test does NOT reproduce the crash (passes in debug and release on unfixed code) - the crash needs the server executor. Red state was reproduced live against the unfixed release binary, exactly per the issue:

```
./.build/release/apfel --serve --port 11499 --max-concurrent 2
req1 status=400   {"stream":true,"messages":[]}
req2 status=400
active_requests: 2          (permits wedged via the then-unfixed #213 leak)
req3 (valid, waits for permit) -> at ~30s: status=000 curl_exit=52
server process GONE (crashed)
/health UNREACHABLE
server log last line: "freed pointer was not the last allocation"
```

Crash report (apfel-2026-07-02-005405.ips): EXC_CRASH SIGABRT, queue com.apple.root.default-qos.cooperative, frames: `swift_Concurrency_fatalError <- swift_task_dealloc <- Task<>.sleep(for:tolerance:clock:) <- closure #1 in closure #1 in AsyncSemaphore.wait(timeout:)` - byte-for-byte the signature in the issue.

Intermediate red (hoist-only attempt, proves the refinement): apfel-2026-07-02-005631.ips, same SIGABRT with the Task created OUTSIDE the continuation body (`closure #1 in AsyncSemaphore.wait(timeout:)`, plus the `@isolated(any)` thunk frames).

**Green evidence:**
- Live, final fix, same setup, run twice back-to-back:
```
--- timeout round 1 --- status=429
--- timeout round 2 --- status=429
server STILL ALIVE
```
(429 body: "Server at max concurrent capacity (2)...", /health reachable.)
- Unit: `swift run apfel-tests` -> "All 703 tests passed" (698 before + 5 new). Also green in release configuration.

## Issue #213 - permit + active_requests leak on early-failing streaming requests

**Root cause confirmed:** YES, exactly as filed. `Sources/Server.swift` released the semaphore + `requestFinished()` only when `!result.trace.stream`; only `streamingResponse`/`structuredStreamingResponse` self-release via StreamCleanup in AsyncStream onTermination. Every stream:true early-return (`chatFailure` from validation at Handlers.swift:57, json_schema missing/invalid at :78/:91, context-build failure at :143, plus the buffered SSE paths `mcpAutoExecuteResponse` streaming and `refusalStreamingResponse`) leaked one permit + one active_requests. Verified live: 2 malformed requests on `--max-concurrent 2` -> `active_requests: 2` permanently.

**What changed (files):** chose the issue's fix option 2 (explicit ownership flag) because `refusalStreamingResponse` and the MCP streaming path legitimately log `stream: true` while being buffered - forcing `stream: false` in `chatFailure` would only fix chatFailure paths and would corrupt log semantics.
- `Sources/Handlers.swift`: `ChatRequestTrace` gains `var ownsCleanup: Bool = false` (documented); only the two live AsyncStream responses (`streamingResponse`, `structuredStreamingResponse`) set `ownsCleanup: true`. `stream` keeps pure logging semantics.
- `Sources/Server.swift`: route cleanup now keyed on `!result.trace.ownsCleanup` (comment explains why not `stream`).
- `Tests/integration/test_stream_permit_release.py` (new).

**Tests added (names):** `Tests/integration/test_stream_permit_release.py` (model-free, uses the shared 11434 conftest fixture server, follows security_test.py BASE_URL pattern):
- `test_validation_failing_streaming_requests_release_permits` (5x empty-messages stream:true -> all 400, active_requests == 0)
- `test_json_schema_failing_streaming_requests_release_permits` (5x missing json_schema.schema -> all 400, active_requests == 0)
- `test_server_still_answers_after_early_failing_streams` (after a 5-burst, a follow-up request gets an instant 400, not a 429/hang; active_requests == 0)

**Red-state evidence:** run against the binary with only #214 fixed:
```
>       assert _active_requests() == 0
E       assert 5 == 0
... later requests: httpx.ReadTimeout: timed out (server wedged, queueing for permits)
============ 3 failed in 21.34s ============
```

**Green evidence:** same command after the fix:
```
test_validation_failing_streaming_requests_release_permits PASSED
test_json_schema_failing_streaming_requests_release_permits PASSED
test_server_still_answers_after_early_failing_streams PASSED
============ 3 passed in 1.71s ============
```

**Manual server verification transcript (release binary, both fixes):**
```
$ ./.build/release/apfel --serve --port 11499 --max-concurrent 2
=== two malformed streaming requests (max-concurrent 2) ===
req1 status=400
req2 status=400
=== /health after ===
active_requests: 0
=== real streaming request (model) ===
stream status=200
=== /health after real stream ===
active_requests: 0            (owned-cleanup path still releases exactly once, no double-release)
=== follow-up non-streaming request answers instantly ===
final status=200
active_requests: 0
```

## Global constraint compliance

- TDD red-to-green per issue: yes (see evidence above; for #214 the red crash state is the live reproduction, as anticipated by the brief).
- `swift build` (debug + release) clean, 0 warnings, before each commit.
- `swift run apfel-tests`: All 703 tests passed before each commit.
- Swift 6 strict concurrency; no `@unchecked Sendable` anywhere in the change (AsyncSemaphore is a plain actor).
- CHANGELOG.md `[Unreleased]` -> `### Fixed`: one bullet per issue, issue numbers included.
- `.version`, `Sources/BuildInfo.swift`, README badge untouched. `git status`: only the untracked `.superpowers/` scratch dir remains.
- No em/en dashes in new text (the pre-existing SemaphoreTimeoutError message string keeps its em dash to preserve behavior byte-for-byte).
- Manual verification used scratch port 11499 only. Ports 11434/11435 were used solely by the pytest conftest fixtures (which start and tear down their own servers, exactly as make test does); no make test was running (checked first) and both ports were verified free beforehand.

## Concerns

1. **#214 crash mechanism is empirical, not sourced.** The allocator abort lives inside the OS Swift runtime (`Task.sleep(for:)` + isolation-inheriting unstructured child task + the server's executor mix, macOS 26.3.1). The unit suite cannot reproduce it (passes even on unfixed code in release), so the regression guard for the crash itself is: (a) the `Task.sleep(nanoseconds:)` choice with a do-not-revert doc comment, and (b) the #213 integration test exercising the permit-timeout machinery in `make test`. If a future macOS fixes the runtime, `Task.sleep(for:)` may become safe again, but there is no reason to switch back.
2. **Integration test couples to the default `--max-concurrent` (5)** via a named constant with a comment. If the default ever changes, the constant needs updating (leaks would still be caught as long as the burst size >= 1, but the instant-400 assertions assume permits are available).
3. **ApfelCore gains public API** (`AsyncSemaphore`, `SemaphoreTimeoutError`). Additive only, so `swift package diagnose-api-breaking-changes` should pass, but it does enlarge the stability-contract surface (STABILITY.md considerations are Franz's call).
4. `make test` / `make preflight` (full 988-test qualification) was intentionally left to the controller per the brief; I ran the full unit suite, the new integration file standalone, and the live manual verifications above.
