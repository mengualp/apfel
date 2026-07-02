## Issue #212: fix(server): negative `seed` crashes the entire server process (remote DoS)

## Summary
A single request with a negative `seed` traps `UInt64.init` and kills the whole server process. This is a remote, unauthenticated DoS: one malformed request takes the server down.

## Reproduction (verified live against the 1.6.1 binary)
```
curl -s http://127.0.0.1:11434/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"apple-foundationmodel","messages":[{"role":"user","content":"hi"}],"seed":-1}'
```
curl exits 52, the process is gone. macOS crash report: faulting frame `Swift runtime failure: Negative value is not representable` → `closure #2 in handleChatCompletion` → `Optional.map`.

## Root cause
- `Sources/Handlers.swift:115` — `seed: chatRequest.seed.map { UInt64($0) },`
- `chatRequest.seed` is a plain `Int` (`Sources/Core/OpenAIModels.swift:25`) and is never validated.
- No `seed` check exists in `Sources/Core/ChatRequestValidator.swift:134-168`.

## Suggested fix
In `ChatRequestValidator.validate`, reject `seed < 0` with `.invalidParameterValue("'seed' must be a non-negative integer")` → HTTP 400. Alternatively convert via `UInt64(exactly:)` and 400 on nil. Add a unit test for the validator and an integration test asserting the server survives `seed:-1` and returns 400.

## Severity
High — remote unauthenticated process crash on the default (`127.0.0.1`) bind.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #213: fix(server): concurrency permit + active_requests leak on early-failing streaming requests (DoS)

## Summary
Every early-exit path of a `"stream": true` request leaks one concurrency permit and one `active_requests` count. `--max-concurrent` (default 5) trivially-malformed streaming requests permanently exhaust capacity → all subsequent requests hang/429 → DoS. Independently reproduced and confirmed by two separate audit passes.

## Reproduction (verified live)
With `--max-concurrent 2`, send two:
```
{"model":"apple-foundationmodel","stream":true,"messages":[]}
```
Both return 400, but `/health` then reports `active_requests: 2` permanently and no further request can acquire a slot (blocks to the 30s timeout). With `--max-concurrent 1`, a single such request wedges the server.

## Root cause
- `Sources/Server.swift:146-149` releases the semaphore + calls `requestFinished()` only when `!result.trace.stream`.
- The only paths that self-release are `streamingResponse` / `structuredStreamingResponse` (via `StreamCleanup` in the AsyncStream `onTermination`).
- When a streaming request fails **before** the stream body is built — validation failure (`Handlers.swift:57-67`), `json_schema` conversion failure (`:75-101`), context-build failure (`:140-152`), or any `mcpAutoExecuteResponse` / `refusalStreamingResponse` path — `handleChatCompletion` returns a buffered `chatFailure(...)` whose `trace.stream` is still `true` but which has no AsyncStream and no `onTermination`. Cleanup is skipped forever.
- (The decode-failure path at `Handlers.swift:42-50` hardcodes `stream:false`, so it is the one safe early path.)

## Suggested fix
Do not key cleanup on `trace.stream`. Either:
1. Make `chatFailure(...)` always set `stream: false` (it never produces an SSE body), OR
2. Add an explicit `ownsCleanup: Bool` to `ChatRequestTrace`, set `true` only in `streamingResponse`/`structuredStreamingResponse`, and have `Server.swift` signal whenever `!ownsCleanup`.

Add an integration test: N+1 streaming validation-failures must leave `active_requests` at 0 and the server still accepting requests.

## Severity
High — remote unauthenticated DoS on the default bind.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #214: fix(concurrency): AsyncSemaphore.wait(timeout:) aborts the whole process on timeout (SIGABRT)

## Summary
When a request waits for a permit and hits the 30s timeout, the process dies with SIGABRT ("freed pointer was not the last allocation") instead of returning 429. This converts a "server busy" condition into a full crash. Independently reproduced by two audit passes; three crash reports share the same faulting frame.

## Reproduction (verified live, deterministic)
`--max-concurrent 1`; block the one slot (e.g. via the leak in the sibling issue, or sustained load), then send one more request. At ~30s the process aborts and `/health` becomes unreachable.

Crash report crashing thread `com.apple.root.default-qos.cooperative`, `EXC_CRASH / SIGABRT`:
```
libswift_Concurrency  swift_Concurrency_fatalError
libswift_Concurrency  swift_task_dealloc
apfel                 closure #1 in closure #1 in AsyncSemaphore.wait(timeout:)
```

## Root cause
`Sources/Retry.swift:31-39` — `wait(timeout:)` spawns an unstructured `Task { [weak self] in try? await Task.sleep(...); await self?.timeoutWaiter(id:) }` **inside** the `withCheckedThrowingContinuation` body. `timeoutWaiter` resumes the continuation (allocated in the parent task frame) from that child task; when the child task deallocates, the cooperative task allocator detects an out-of-order free and aborts. Fires on every genuine timeout.

## Suggested fix
Never resume a `CheckedContinuation` from an unstructured `Task` spawned inside the continuation body. Restructure the timeout as a structured race (e.g. `withThrowingTaskGroup` racing the acquire against `Task.sleep`, first-wins + cancel loser), or store the sleeping `Task` handle on the actor and `cancel()` it in `signal()` so the timeout task is torn down in order. Add a unit test that forces a `wait` timeout and asserts a thrown `SemaphoreTimeoutError` (not a crash).

## Severity
High — process crash under legitimate saturation, trivially reachable when combined with the permit-leak issue.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #215: fix(mcp): writing to a crashed MCP server's stdin kills the whole apfel process (SIGPIPE)

## Summary
If an MCP server crashes between calls, the next tool call writes to a pipe whose read end is closed → SIGPIPE with default disposition → apfel exits 141 with no message. In `--serve` mode this takes down the entire HTTP server. A remote/third-party MCP server can therefore crash the local process.

## Root cause
- `Sources/MCPClient.swift:118-121` — `send(_:)` uses the legacy non-throwing `FileHandle.write(_:)` on `stdinPipe.fileHandleForWriting`.
- `grep -rn SIGPIPE Sources/` finds no `signal(SIGPIPE, SIG_IGN)` anywhere.
- Even if SIGPIPE were ignored, the legacy `FileHandle.write(_:)` raises an uncatchable ObjC `NSFileHandleOperationException` on EPIPE, which also crashes Swift.

## Suggested fix
1. `signal(SIGPIPE, SIG_IGN)` once at MCP/startup, AND
2. Guard the write: check `process.isRunning` first, then use `try stdinPipe.fileHandleForWriting.write(contentsOf: data)` inside do/catch, mapping failures to `MCPError.processError`.

## Severity
High — remote-server-controlled crash of the local process; server-mode DoS.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #216: fix(mcp): timed-out MCP connection stays registered — permanently dead tool + zombie child

## Summary
When a tool call times out, the connection is terminated but never removed from `MCPManager.connections`/`toolMap`. Every subsequent request routed to that tool calls `send()` on the dead pipe (→ the SIGPIPE crash in the sibling issue), and the model keeps being offered the dead tool via `allTools()`. The child is also never reaped (zombie).

## Root cause
- `Sources/MCPClient.swift:87-92` — `callTool` does `if case .timedOut = error as? MCPError { shutdown() }`, but `connections`/`toolMap` are never updated; no removal, restart, or dead-flag.
- `shutdown()` (`MCPClient.swift:100-102`) is `process.terminate()` only — no `waitUntilExit()`, so the child lingers as a zombie for the process lifetime.

## Failure scenario
One slow tool call (>5s default timeout) on `apfel --serve --mcp server.py` → connection terminated; every later request to that tool hits the dead pipe → server crash (or, once the crash is fixed, a permanently dead tool with no recovery).

## Suggested fix
On timeout-shutdown: remove the connection's tools from `toolMap` (or set a `dead` flag returning `MCPError.processError` fast), reap with `waitUntilExit()` after `terminate()`, and optionally escalate SIGTERM→SIGKILL after a grace period. Remove the tool from `allTools()` output.

## Severity
High.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #217: fix(mcp): JSON-RPC response ids are never correlated — a single server notification desyncs the connection

## Summary
`sendAndReceive` returns whatever the next stdout line is, with no JSON-RPC `id` matching. MCP servers legitimately emit server→client notifications interleaved with responses (e.g. `notifications/message` logging — FastMCP's `ctx.info()` does exactly this — `notifications/tools/list_changed`, or `ping`). The notification line gets parsed as the tool response (→ "Missing content" error), and the real response stays buffered, so every subsequent call is off-by-one forever.

## Root cause
- `Sources/MCPClient.swift:123-133` — `sendAndReceive` does `send(message); return try lineReader.readLine(...)` with no loop and no id check.
- `Sources/Core/MCPProtocol.swift:112-130` — `parseToolCallResponse` never inspects `obj["id"]`.

## Suggested fix
In `sendAndReceive`, loop `readLine()` (sharing one deadline) until a message whose `"id"` equals the request id arrives; skip messages without `id` (notifications); reply to `ping` requests. Correlate on `id` in `parseToolCallResponse`.

## Severity
High — silent wrong-result delivery after a single log line from the server.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #218: fix(mcp): concurrent tool calls on one connection cross-deliver responses

## Summary
In `--serve` mode, two simultaneous tool calls on the same MCP connection can receive each other's responses, and interleaved stdin writes can corrupt arguments larger than PIPE_BUF (512 bytes on Darwin).

## Root cause
- `Sources/MCPClient.swift:279-293` — `AnyMCPConnection.callTool` runs local stdio I/O via `Task.detached { try c.callTool(...) }`, so the `MCPManager` actor is not blocked during the await and dispatches a second `execute()` to the same `MCPConnection`.
- `MCPConnection` has no per-request lock: `send()` is unguarded and `BufferedLineReader.readLine` serializes only the read (`BufferedLineReader.swift:42-119`). Request A sends, B sends, B wins the `state.withLock` race and reads A's response.

## Failure scenario
`apfel --serve --max-concurrent 5 --mcp server.py`; two simultaneous chat requests each triggering a tool call → swapped results, or interleaved stdin writes for args > 512 bytes.

## Suggested fix
Hold one `NSLock` around the full send+receive pair in `MCPConnection.callTool` (serialize per-connection requests), or implement proper id-based multiplexing (pairs well with the id-correlation issue). Serialize `send()` on the notification path too.

## Severity
High in server mode; latent in CLI (single-threaded).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #219: fix(schema): anyOf/oneOf/type-arrays silently degrade to an empty object schema

## Summary
Any schema node without a scalar `"type"` — `{"anyOf": [...]}`, `{"oneOf": [...]}`, or `{"type": ["string","null"]}` — defaults to `"object"` with no `properties`, producing a native tool definition with an **empty** parameter schema. The designed text-fallback path (which would inject the true schema as text) never fires. Optional parameters are extremely common: every Optional field in a Pydantic/zod-generated MCP schema emits `anyOf: [{type:X},{type:"null"}]`.

## Root cause
- `Sources/Core/SchemaParser.swift:32` — `let type = schema["type"] as? String ?? "object"`.
- `Sources/SchemaConverter.swift:74-105` — successful parse → `.object(name:_, properties: [])`, so the fallback branch is skipped.
- Same parser feeds `response_format: json_schema` via `SchemaConverter.generationSchema` (`Handlers.swift:89`), so a caller's union schema is accepted with 200 but generation is unconstrained.

## Failure scenario
Attach any FastMCP/TS-SDK server whose tool has an optional parameter → the model is told the tool takes `{}` and emits argument-less calls.

## Suggested fix
In `parseObject`, detect `anyOf`/`oneOf`/`allOf` and non-string `type`:
- For the common `anyOf:[X, {type:"null"}]` pattern, parse `X` with optional semantics.
- Otherwise `throw Error.unsupportedType(...)` so the existing text-injection fallback engages (for tools) and the server returns an honest 400 (for `json_schema`).

## Severity
High — silent correctness loss on real-world MCP tool schemas.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #220: fix(mcp): isError tool result aborts the request with HTTP 500 instead of feeding the error back to the model

## Summary
An MCP-spec-conformant tool result with `isError: true` (e.g. `divide(1,0)` → "division by zero") is turned into a thrown error that kills the request with HTTP 500, instead of being fed back to the model so it can recover. Per the MCP spec, execution errors "should be reported inside the result object... so the LLM can see it and act."

## Root cause
- `Sources/MCPClient.swift:93-97` — `callTool` converts `isError: true` into `throw MCPError.serverError(...)`.
- `Sources/Session.swift:334-347` — `detectAndExecuteMCPTools` only absorbs `.toolNotFound`; every other `MCPError` is re-thrown → `.toolExecution` → HTTP 500 (`ApfelError.swift:129`) / CLI runtime error.

## Suggested fix
Return a `ToolCallResult` (text + isError) from `callTool` instead of throwing for `isError`. In `detectAndExecuteMCPTools`, record it like the existing `toolNotFound` branch: `resultParts.append("\(call.name): error - \(text)")`, so the model sees the error and can act.

## Severity
Medium-High — directly answers "does a failing tool call surface usefully?" Today it does not.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #221: fix(mcp): tool results are never truncated against the 4096-token window before re-prompt

## Summary
A large tool result (file reader, web fetch, DB query — tens of KB is normal) is fed back verbatim on the 4096-token model. In CLI mode this dies with "Input exceeds the 4096-token context window" *after* the tool already ran; in server mode the ContextManager drops the oversized tool message entirely while still instructing "Respond based on the tool result above" → confident hallucination.

## Root cause
- `Sources/Session.swift:367-390` (CLI) — `plainSession.respond(to: "...The tool returned: \(toolResult)...")` with no size check.
- `Sources/Session.swift:441-466` (server) — full result appended as a `role:"tool"` message; ContextManager's newest-first trimming treats it as one atomic entry, so a result bigger than budget makes `keepCount = 0` and the tool result is dropped while the synthetic prompt still references it.

## Suggested fix
Token-count the tool result and truncate head+tail to a budget (`inputBudget − prompt − reserve`) with an explicit `"[tool output truncated: N of M tokens shown]"` marker before building the follow-up prompt.

## Severity
Medium-High — guaranteed to bite given the product's headline 4096-token constraint.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #222: fix(cli): no-args pipe fast path ignores every APFEL_* env var and skips the model-availability check

## Summary
The flagship `echo "prompt" | apfel` path runs **before** `CLIArguments.parse()` is ever called, so `APFEL_SYSTEM_PROMPT`, `APFEL_TEMPERATURE`, `APFEL_MAX_TOKENS`, `APFEL_MCP`, `APFEL_DEBUG`, and `APFEL_CONTEXT_*` are all silently dropped and `SessionOptions.defaults` is used. It also bypasses the `TokenCounter.shared.availability` gate, so an unavailable model surfaces as a classified runtime error instead of the documented exit 5 + remediation text.

## Reproduction (verified live)
```
echo "greet me" | APFEL_SYSTEM_PROMPT="reply with exactly BANANA" apfel
# → "Hello! How can I assist you today?"   (env ignored)
echo "greet me" | APFEL_SYSTEM_PROMPT="reply with exactly BANANA" apfel --stream
# → "BANANA"                                (env honored on the parsed path)
```

## Root cause
`Sources/main.swift` — `if rawArgs.isEmpty { ... try await singlePrompt(input, systemPrompt: nil, stream: true) }` with a comment claiming it "must stay above the parse() call". Nothing about `parse()` requires that: `parse([], env:)` is pure and cheap. The man page ENVIRONMENT section and `--help` both promise the env vars apply to every invocation.

## Suggested fix
Delete the fast path. When `rawArgs.isEmpty`, still call `CLIArguments.parse([], env: ProcessInfo.processInfo.environment)` and fall through to the existing `.single`/stdin-merge path, defaulting `stream: true` for the no-args pipe if that behavior must be preserved. Keep only the "no args AND stdin is a TTY → printUsage" branch.

## Severity
High — the documented env-var contract is silently broken on the primary pipe use case.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #223: fix(server): response_format json_object fence-stripping is not applied on the streaming path

## Summary
`stream:true` + `{"response_format":{"type":"json_object"}}` delivers markdown-fenced content; the concatenated stream is not valid JSON, violating the json_object contract that the non-streaming path enforces.

## Reproduction (verified live)
First content delta = `` "```json\n{\n  \"" ``.

## Root cause
- `Sources/Handlers.swift:196-202` — call site passes no `jsonMode` arg; `streamingResponse` signature (`:464-474`) has no `jsonMode`.
- `JSONFenceStripper.strip` is applied only at `Handlers.swift:425` (non-streaming) and `:305` (MCP).

## Suggested fix
For jsonMode streaming, buffer as the structured path does (`Handlers.swift:839-854` precedent: buffer snapshots, emit one delta) and emit `JSONFenceStripper.strip(prev)` as a single content delta before the stop chunk; or strip a leading ```` ```json ```` line and trailing fence on the fly.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #224: fix(server): streamed tool calls leak raw tool_calls JSON as content deltas; finish_reason rides in the tool_calls chunk

## Summary
On `stream:true` with tools in play (client-supplied `tools` or MCP), the SSE loop forwards every model delta as `delta.content` and only detects tool calls **after** the stream ends. OpenAI clients therefore receive the tool-call JSON as assistant text (` ```json\n{"tool_calls":[{"id":"call_1"... `) *and then* a proper `tool_calls` delta. OpenAI never emits tool-call text as content, and it sends the `finish_reason` in a separate trailing chunk, not in the same chunk as the tool_calls delta. (Reported independently by the server and MCP audits.)

## Root cause
`Sources/Handlers.swift:509-563` — deltas are yielded live (`:514-525`); `ToolCallHandler.detectToolCall(in: prev)` runs only at `:529`; the tool chunk (`:550-559`) sets both `tool_calls` and `finish_reason` in one `ChunkChoice`. No buffering when `chatRequest.tools` is present.

## Suggested fix
When tools are in play, hold back emission while the accumulated content is a plausible tool-call prefix (trimmed content starts with ```` ``` ```` or `{"tool_calls"`), flushing as content only once it diverges — or buffer fully like the MCP path already does. On detection, emit only the tool_calls delta chunk, then a separate empty-delta chunk carrying `finish_reason: "tool_calls"`.

## Severity
Medium-High — visible protocol defect on the flagship OpenAI-compat surface.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #225: ci(release): publish-release.yml is a stale, divergent path that can publish an unqualified release

## Summary
The `workflow_dispatch` release path in `publish-release.yml` (last run 2026-04-12; all releases since v1.0.x are local via `publish-release.sh`) has drifted behind the local script and would produce a broken release if dispatched.

## Gaps (`.github/workflows/publish-release.yml`)
- **No server-readiness gate.** Lines 88-95 loop waiting for `/health` but never fail on timeout. Compare `Makefile:217` and `publish-release.sh:82`. If servers don't start, `conftest.py:70-101` session fixtures `pytest.skip(...)` the entire suite, pytest exits 0, and the workflow tags + publishes.
- **No CHANGELOG stamp.** Line 115 commits only `.version README.md Sources/BuildInfo.swift`; `publish-release.sh:100-102` runs `stamp-changelog.sh` and commits `CHANGELOG.md`. A workflow release regresses #201 and leaves `[Unreleased]` unstamped.
- **No nixpkgs bump** (`publish-release.sh:158-169` absent).
- **Self-contradiction:** line 100 runs `performance_test.py` on the GH runner, while `ci.yml:56` says it "requires Apple Intelligence". `performance_test.py:19` asserts `returncode == 0`, so the step likely fails — the workflow is effectively dead but still dispatchable.

## Suggested fix
Either delete the workflow (CLAUDE.md mandates local releases), or bring it to parity: add the `READY` fail-check, call `stamp-changelog.sh` + commit `CHANGELOG.md`, drop `performance_test.py`, add a `concurrency:` group.

## Severity
High — a dispatch could publish an unqualified/broken release.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #226: build(release): tarball is ad-hoc signed (not Developer ID/notarized) and ships no checksum asset; CLAUDE.md claims otherwise

## Summary
CLAUDE.md ("Distribution channels") claims "All pull the same **signed** tarball from each GitHub Release." The shipped v1.6.1 asset is only ad-hoc signed, and no checksum is published as a release asset.

## Evidence
`codesign -dvv` on the v1.6.1 binary → `flags=0x20002(adhoc,linker-signed)`, `Signature=adhoc`, `TeamIdentifier=not set`. No `codesign`/`notarytool`/`productsign` invocation exists in `Makefile`, `scripts/*.sh`, or `.github/workflows/` (zero grep hits). `gh release view v1.6.1` shows a single asset — no `checksums.txt`/`.sha256`. The sha256 lands only in the tap formula.

## Consequences
- Gatekeeper quarantine blocks any non-brew download path.
- A malicious asset swap (`gh release upload --clobber` is wired in at `publish-release.sh:126`) is undetectable by users — no independent checksum asset.

## Suggested fix
In `Makefile:package-release-asset`: `codesign --force --options runtime --sign "Developer ID Application: Franz Enzenhofer (7D2YX5DQ6M)"` the binary, `xcrun notarytool submit` + staple; upload `apfel-<v>-arm64-macos.tar.gz.sha256` as a second release asset; have `post-release-verify.sh` download the asset and compare its digest to the tap formula's `sha256`. **Alternatively**, correct CLAUDE.md/README to stop claiming the tarball is signed.

## Severity
High (supply-chain integrity + false documentation).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #227: test(integration): infrastructure failures convert to skips, so a startup-breaking regression passes release qualification

## Summary
CLAUDE.md says "Never skip tests. A skipped test is a critical error." Nothing enforces it. pytest exits 0 when tests skip, and no invocation checks skip counts, so a regression that prevents startup turns the suite green-by-skip and `make release` publishes.

## Concrete regression vector
`Tests/integration/mcp_remote_test.py:124` — if `apfel --serve --mcp <http-url>` fails to become healthy (remote-MCP broken), the fixture does `pytest.skip("apfel with remote MCP did not become healthy")` and all 17 remote-MCP tests pass by skipping. Same pattern at lines 102/190/214/245 and the whole-suite session guards in `conftest.py:79,101`.

## Suggested fix
Add a `pytest_sessionfinish` hook in `conftest.py` that sets `session.exitstatus = 1` when any test skipped and `APFEL_REQUIRE_FULL=1` is set; export that env var in `publish-release.sh`, `release-preflight.sh`, and `make test`. Change the server-didn't-start fixture skips in `mcp_remote_test.py` to `pytest.fail`.

## Severity
High — release qualification can pass with core features broken.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #228: fix(security): non-loopback bind without a token starts with zero auth and no warning

## Summary
`apfel --serve --host 0.0.0.0` (or `APFEL_HOST=0.0.0.0`) with no token starts silently with no authentication and no warning. The whole security model rests on loopback binding; removing loopback removes all protection and nothing replaces it.

## Root cause
- `Sources/Server.swift:229-248` — the only network-exposure warning is the `--footgun` branch (`!originCheckEnabled && cors`). There is no branch for `!isLoopbackHost(config.host) && config.token == nil`.
- `Sources/Core/OriginValidator.swift:23` — `isAllowed` returns `true` for a nil Origin header, and non-browser clients (curl, SDKs, scanners) send no Origin.
- `docs/background-service.md:63` and `docs/server-security.md:433` tell operators to set a token when binding `0.0.0.0`, but nothing enforces or warns it.

## Attack scenario
Operator binds `0.0.0.0` to reach the server from another device. Every host on the LAN can now hit `/v1/chat/completions` with no Origin header → unlimited free inference, prompt injection into workflows trusting the endpoint, DoS via the concurrency semaphore.

## Suggested fix
In `startServer`, when `!isLoopbackHost(config.host) && config.token == nil`, emit a red banner warning as prominent as the footgun warning. Stronger: refuse to bind non-loopback without `--token`/`--token-auto` unless an explicit `--i-know-this-is-exposed`-style opt-in is passed (mirrors the footgun opt-in).

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #229: fix(security): local MCP subprocess inherits the full parent environment (secret leakage to tool scripts)

## Summary
Local MCP subprocesses are spawned without setting `proc.environment`, so Foundation `Process` inherits apfel's entire environment — including `APFEL_TOKEN`, `APFEL_MCP_TOKEN`, and any other secrets in the shell — and hands them to the third-party tool script it is supposed to be isolated from.

## Root cause
`Sources/MCPClient.swift:32-52` (`MCPConnection.init`) sets `executableURL`, `arguments`, and the std pipes but never assigns `proc.environment`. With `environment == nil`, `Process` inherits the parent env.

## Attack scenario
`apfel --serve --token $APFEL_TOKEN --mcp ./community-tool.py` — the child reads `os.environ` and exfiltrates the server's own bearer token plus any cloud/API keys in the shell.

## Suggested fix
Pass an explicit minimal environment to the child (`proc.environment = ["PATH": ..., "HOME": ...]`) that excludes `APFEL_TOKEN`/`APFEL_MCP_TOKEN` and other apfel secrets, or at minimum strip the apfel-specific auth vars before spawn. Document that local MCP scripts run with a scrubbed env.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #230: fix(security): no Host-header validation — DNS-rebinding can reach the GET endpoints

## Summary
The security middleware validates only `Origin`. Same-origin GET requests carry no Origin header, so `isAllowed(origin: nil, …)` returns `true`, and there is no `Host` allowlist (the canonical DNS-rebinding defense).

## Attack scenario
Victim visits `http://attacker.com:11434/`; after DNS TTL expiry the domain rebinds to `127.0.0.1`; the page issues `fetch('http://attacker.com:11434/v1/models')` / `/health` (same-origin GET, no Origin header) → apfel serves it, leaking model metadata, supported languages, and active-request counts. Bounded: `/v1/chat/completions` is POST-only and same-origin POST *does* send an Origin that fails the allowlist, so rebinding cannot drive inference.

## Root cause
`Sources/SecurityMiddleware.swift:20-52` inspects only `Origin`; `Sources/Core/OriginValidator.swift:22-23` returns `true` for nil Origin.

## Suggested fix
When `originCheckEnabled`, reject requests whose `Host` header is not `localhost`/`127.0.0.1`/`[::1]` (+ configured port), independent of Origin.

## Severity
Low (info leak only; inference is not reachable).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #231: fix(security): bearer token compared with non-constant-time ==

## Summary
`Sources/Core/OriginValidator.swift:59` — `return !token.isEmpty && token == expected`. Swift `String ==` short-circuits on the first differing byte, so comparison time correlates with the shared prefix length.

## Assessment
Near-infeasible over a network with UUID-random tokens and NIO scheduling jitter, and only reachable if bound non-loopback or from a co-resident local process — hence Low. But it is a real deviation from the project's own "usable security" bar and PR checklist.

## Suggested fix
Constant-time compare: XOR-accumulate over the max length of both byte arrays with a length check that does not early-return.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #232: fix(security): --no-origin-check (without --cors) disables origin validation without the loud footgun warning

## Summary
The prominent red "no origin check" warning fires only when **both** origin-check-off **and** CORS-on. `--no-origin-check` alone (CORS defaults false) turns off origin validation but shows only the muted status line `disabled (all origins allowed)`, not the loud multi-line warning that `--footgun` gets.

## Root cause
`Sources/Server.swift:243` — warning gate is `if !config.originCheckEnabled && config.cors`.

## Suggested fix
Trigger the prominent warning whenever `!config.originCheckEnabled`, regardless of the CORS flag.

## Severity
Low (informational).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #233: fix(server): empty or null content in the last user message returns 500 instead of 400

## Summary
`{"messages":[{"role":"user","content":""}]}` and `content:null` both return `HTTP 500 {"error":{"message":"Last message has no text content","type":"server_error"}}` — a client-input problem reported as a server fault.

## Root cause
`Sources/ContextManager.swift` (`makeSession`): `guard let text = conversation.last?.textContent, !text.isEmpty else { throw ApfelError.unknown("Last message has no text content") }`, surfaced at `Handlers.swift:140-152`; `ApfelError.unknown` maps to 500/`server_error` (`ApfelError.swift:118-131`).

## Suggested fix
Add a `ChatRequestValidationFailure` case (`.emptyLastMessageContent`) checked in `ChatRequestValidator.validate` → 400 `invalid_request_error`; or a dedicated `ApfelError` case mapping to 400.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #234: fix(server): >1 MiB request body returns a bare 413 with no error object, no CORS headers, no request log

## Summary
A request body over 1 MiB yields `HTTP/1.1 413 Payload Too Large` with `Content-Length: 0` — no OpenAI error object, no CORS headers (so browser clients can't read it), and no `RequestLog` entry.

## Root cause
`Sources/Handlers.swift:33` — `try await request.body.collect(upTo: BodyLimits.maxRequestBodyBytes)` throws; rethrown at `Server.swift:139-145`, bypassing `SecurityMiddleware.applyCORSHeaders` (applied only to non-throwing `next()`, `SecurityMiddleware.swift:56-59`).

## Suggested fix
Wrap the `collect` in do/catch inside `handleChatCompletion` and return `chatFailure(status: .contentTooLarge, message: "Request body exceeds 1 MiB limit", type: "invalid_request_error", ...)`.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #235: fix(validator): out-of-range top_p and temperature pass through and surface as opaque 500s

## Summary
`top_p: 2.0` and `top_p: -0.5` both return `HTTP 500 (FoundationModels ... GenerationError -1)`. OpenAI 400s for `top_p` outside [0,1]. Related: `temperature` has only a `< 0` lower-bound check, so `temperature: 5.0` is accepted (OpenAI caps at 2).

## Root cause
- `Sources/Core/ChatRequestValidator.swift:155-166` — no `top_p` check.
- `Sources/Core/SamplingDecision.swift:36-38` — any `top_p` → nucleus sampling → passed to FoundationModels → opaque error.

## Suggested fix
In `ChatRequestValidator.validate`, add `.invalidParameterValue` for `top_p` outside `0...1` and for `temperature > 2` → 400.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #236: fix(server): error object omits param/code; unknown model should be 404 model_not_found

## Summary
The error body is `{"error":{"message":...,"type":...}}`. OpenAI always emits `"param": null, "code": null`, and returns unknown-model errors as HTTP **404** with `"code": "model_not_found"`, `"param": "model"`. Router/proxy front-ends that branch on `error.code` miss it.

## Root cause
- `Sources/Models.swift:150-158` — synthesized `ErrorDetail` encoding drops nil `param`/`code`.
- `Sources/Handlers.swift:57-67` + `ChatRequestValidator.swift:139-141` — `invalidModel` → 400.

## Suggested fix
Add a manual `encode(to:)` on `ErrorDetail` using `encodeNil` for absent `param`/`code` (pattern already used at `Models.swift:77-83`); route `.invalidModel` to status 404 with `code: "model_not_found"`, `param: "model"`.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #237: fix(server): unknown x_context_strategy values silently fall back to newest-first

## Summary
`x_context_strategy: "sliding-window"` (typo for `sliding_window`) is silently ignored while sibling params `x_context_max_turns`/`x_context_output_reserve` are strictly validated. The caller believes their strategy is active.

## Root cause
`Sources/Handlers.swift:104-108` — `strategy: chatRequest.x_context_strategy.flatMap { ContextStrategy(rawValue: $0) } ?? .newestFirst`.

## Suggested fix
In `ChatRequestValidator`, reject a non-nil `x_context_strategy` that doesn't map to a `ContextStrategy` case with 400 listing the valid values.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #238: fix(sse): non-usage chunks omit "usage": null with include_usage; invalid tool_choice silently coerced to auto

## Summary
Two OpenAI wire-format deviations:
1. With `stream_options.include_usage: true`, OpenAI sends `"usage": null` on every chunk except the final stats chunk; apfel omits the key entirely (`Sources/Models.swift:97-103`, synthesized encoder drops optional `usage`).
2. `ToolChoice.init(from:)` (`Sources/Core/OpenAIModels.swift:337-365`) maps any unrecognized string (`"banana"`) and any undecodable object to `.auto`; OpenAI rejects invalid `tool_choice` with 400.

## Suggested fix
- Add a manual `encode(to:)` on `ChatCompletionChunk` that emits explicit `usage: null` when the flag is set (plumb `includeUsage` through the SSE builders).
- Make `ToolChoice` decoding throw (or decode to `.invalid(String)` rejected by the validator).

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #239: fix(mcp): tool-name collisions across multiple --mcp servers silently shadow earlier servers

## Summary
When two MCP servers expose a tool with the same name, the last-registered one wins with no warning, and both identical-named schemas are injected into the 4096-token prompt.

## Root cause
- `Sources/MCPClient.swift:323-326` — `for tool in conn.tools { toolMap[tool.function.name] = conn }` (last writer wins).
- `Sources/MCPClient.swift:336-338` — `allTools()` is `connections.flatMap(\.tools)`, so duplicates are all injected.

## Failure scenario
`apfel --mcp fs-server.py --mcp git-server.py`, both exposing `search` → every call routes to git-server regardless of which schema the model followed; the fs-server variant is unreachable and wastes context tokens.

## Suggested fix
On duplicate names, prefix (`s1_search`) with a reverse map in `execute`, or skip the duplicate and `printStderr` a loud warning. Deduplicate `allTools()`.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #240: fix(server): MCP auto-execute (server path) does one round — chained tool calls leak raw JSON with finish_reason stop

## Summary
The server-side MCP auto-execute path runs exactly one round and returns the follow-up content verbatim. If the model answers the tool-result follow-up with another `{"tool_calls": ...}` (common in tool chains), the HTTP client receives raw tool-call JSON as `message.content` with `finish_reason: "stop"`.

## Root cause
- `Sources/Session.swift:441-467` (`executeMCPToolCallsForServer`) executes once and returns `followUpSession.respond(...).content`.
- `Sources/Handlers.swift:272-307` — `mcpAutoExecuteResponse` uses it directly (`content = executed.content`) with hardcoded `finishReason = "stop"`.
- The CLI path (`Session.swift:355-400`) already has the bounded re-detection loop (`maxReprompts = 3`) + `stripToolCallJSON` on cap exhaustion; the server path lacks both.

## Suggested fix
Port the CLI's bounded loop + `stripToolCallJSON` into `executeMCPToolCallsForServer` (helpers already exist and are shared).

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #241: fix(mcp): malformed tool-call arguments are silently replaced with {} before hitting the server

## Summary
When the model emits malformed JSON arguments (e.g. `{lat: 48.2, lon:` truncated), the tool is invoked with **no arguments** instead of erroring. A tool with all-optional params "succeeds" with defaults and the user gets a confidently wrong answer with no trace.

## Root cause
`Sources/Core/MCPProtocol.swift:43` — `let argsObj = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [:]` in `toolsCallRequest`.

## Suggested fix
On parse failure, throw `MCPError.invalidResponse` (or a new `.invalidArguments`) from the call site so it surfaces in the tool log as an error result the model can retry on.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #242: fix(mcp): parseToolCallResponse rejects valid non-text/empty results and drops multi-block content

## Summary
`parseToolCallResponse` requires `content[0].text` to be a string, so it rejects spec-legal results with empty content or a non-text first block, and silently drops every content block after the first. It also can't handle `structuredContent`-only results (2025-06-18 spec — exactly the `protocolVersion` apfel advertises at `MCPProtocol.swift:13`).

## Root cause
`Sources/Core/MCPProtocol.swift:121-126` — `guard ... let first = content.first, let text = first["text"] as? String else { throw MCPError.invalidResponse("Missing content...") }`.

## Failure scenario
A side-effect tool returning `content: []`, or `[{type:"image"},{type:"text"}]`, fails the whole request; a multi-text-block result loses everything after block 0.

## Suggested fix
Collect all `type=="text"` items joined with `\n`; empty content → `""` (or `"(no output)"`); fall back to serializing `structuredContent` when no text blocks exist.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #243: fix(schema): JSON Schema "number" is generated as Int — fractional values are unreachable in structured output

## Summary
`response_format: json_schema` with a `{"type":"number"}` property can only ever produce integers — `{"price": 9.99}` / `{"temperature": 0.7}` outputs are impossible, silently.

## Root cause
- `Sources/SchemaConverter.swift:163-167` — `case .number: return DynamicGenerationSchema(type: Int.self)`.
- `Sources/Core/SchemaIR.swift:21` — the IR deliberately conflates `integer` + `number`.

## Suggested fix
Split the IR case (`.integer` / `.number`) and map `number` → `DynamicGenerationSchema(type: Double.self)`.

## Severity
Medium (for the `response_format: json_schema` surface).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #244: fix(toolcall): model tool calls without an "id" field are silently dropped, leaking raw JSON to the user

## Summary
If a model-emitted tool call lacks an `"id"`, the whole `{"tool_calls":...}` block is treated as normal reply text and printed/streamed to the user verbatim — no tool executes. The on-device 3B model routinely deviates from the exact prompt format (the codebase already defends against unclosed brackets, preambles, string-vs-object `function`); omitting `id` is the one deviation that still hard-fails.

## Root cause
`Sources/Core/ToolCallHandler.swift:234` — `guard let id = call["id"] as? String else { continue }`; if all entries lack `id`, `parseToolCallJSON` returns nil → `detectToolCall` returns nil.

## Suggested fix
Synthesize an id when missing: `"call_\(UUID().uuidString.prefix(8))"`, consistent with the existing lenient-parsing philosophy.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #246: fix(mcp): graceful shutdown at process exit is a fire-and-forget Task that frequently never runs

## Summary
`defer { Task { await mcpManager?.shutdown() } }` (`Sources/main.swift:233`) fires as async main returns; the process exits before the unstructured Task is scheduled, so children only die on stdin EOF (a server ignoring EOF is orphaned). On `exit()` paths (e.g. `--count-tokens --strict` overflow at exit 4, "no prompt" at exit 2 after MCP init) the defer never runs at all. The remote branch is doubly fire-and-forget (`MCPClient.swift:299`) and `RemoteMCPConnection.shutdown()`'s DELETE (`:212`) is never awaited before exit. (Reported by both the CLI and MCP audits.)

## Suggested fix
Make shutdown synchronous-before-exit: `await mcpManager?.shutdown()` directly in the exit path (main is already async), and before the `exit()` calls that can follow MCP init, with `terminate()` + bounded `waitUntilExit()` for locals and an awaited DELETE for remotes.

## Severity
Low-Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #247: perf(schema): SchemaConversionCache.insert wipes the entire cache when full

## Summary
`Sources/SchemaConverter.swift:47-52` — `if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }`. The 65th distinct tool-set evicts all 64, including hot entries; two alternating clients each with >32 distinct tool sets cause pathological full-flush churn.

## Suggested fix
Simple LRU (order array + remove-first) or random single-entry eviction.

## Severity
Low (correctness unaffected).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #248: fix(cli): `apfel demos --help` writes 9 files to disk instead of showing help

## Summary
`apfel demos --help` / `apfel demos -h` immediately writes `./apfel-demos/` (9 files) into cwd (verified: exit 0, "wrote 9 demo files"). Any flag after `demos` (`-q`, `-o json`, unknown flags) is silently discarded — no unknown-option error.

## Root cause
`Sources/CLI/CLIArguments.swift:232-240` — `if args.first == "demos" { result.mode = .demos; if args.count > 1, !args[1].hasPrefix("-") { result.demosTarget = args[1] }; return result }`.

## Suggested fix
In the subcommand branch, iterate remaining args: accept one non-dash token as target, handle `-h/--help` → `.help`, and throw `CLIErrors.unknownOption` for any other dash token.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #249: fix(output): color is gated on stdout's TTY even for stderr writes — ANSI garbage in redirected stderr

## Summary
`styled()` keys colorization off `isatty(STDOUT_FILENO)`, but it's used for stderr writes too. `apfel --bogus-flag 2>err.log` in a terminal writes `\x1b[31m\x1b[1merror:\x1b[0m ...` into the log (verified via hexdump). Conversely `apfel ... | cat` with stderr on a TTY prints uncolored errors. Log files from cron/launchd wrappers get escape-polluted.

## Root cause
`Sources/Output.swift:43` — `let isTerminal = isatty(STDOUT_FILENO) != 0`, used by `printError` (`:59-61`) and stderr call sites in `main.swift`, `CLI.swift:74`, `Session.swift:300-308` (tool log).

## Suggested fix
Add `styledErr(_:_:)` (or `styled(_:for fd:)`) checking `isatty(STDERR_FILENO)`, and route all stderr-destined styling (`printError`, embedded `styled(...)` in `printStderr` call sites, `printToolLog`, `debugLog`) through it.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #250: fix(cli): usage text is written to stdout on usage-error exits (exit 2)

## Summary
Usage-error paths (exit 2) print ~4.8 KB of usage text to **stdout**, polluting downstream pipes. Verified: `apfel </dev/null` → exit 2, stdout 4773 bytes, stderr 0 bytes.

## Root cause
`Sources/main.swift` no-args/empty-stdin path → `printUsage(); exit(exitUsageError)`; `Sources/CLI.swift:575` `printUsage()` uses `print` (stdout).

## Suggested fix
Give `printUsage(to:)` a destination parameter. Error paths print usage to stderr; the `.help` mode keeps stdout + exit 0.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #251: fix(chat): SIGINT handler _exit(130)s out of libedit without restoring the terminal; exit 130 undocumented

## Summary
Ctrl-C at the chat prompt runs `apfel_sigint_exit_handler` → `_exit(130)`, skipping libedit's `rl_deprep_terminal`/atexit cleanup, so termios are left in raw/no-echo mode. zsh repairs its own tty, but `sh`, script wrappers, and expect-style harnesses inherit a broken terminal. Also, exit code 130 is documented nowhere (man page EXIT STATUS lists only 0–6).

## Root cause
`Sources/CReadline/shim.h` — `apfel_sigint_exit_handler` writes a reset + newline then `_exit(130)`; `apfel_readline_interruptible` installs it around `readline(prompt)`.

## Suggested fix
Capture `tcgetattr(STDIN_FILENO, &saved)` before installing the handler and call `tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)` inside the handler (`tcsetattr` is async-signal-safe). Add `130` (interrupted) to the man page EXIT STATUS and `--help` EXIT CODES.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #252: fix(chat): context-rotation failure in chat mode exits 0

## Summary
If context rotation throws during a chat session (e.g. `--context-strategy strict` with history over budget → `truncateTranscript` throws `contextOverflow`), the loop breaks, "Goodbye." prints, and the process exits 0 — so a wrapper script sees success despite the session dying. Single-prompt mode maps the same error to exit 4.

## Root cause
`Sources/CLI.swift:320-324` — `catch { let classified = ApfelError.classify(error); printError(...); break }`; `break` returns from `chat()` normally → exit 0.

## Suggested fix
Replace `break` with `throw error` (main.swift's top-level catch maps it via `exitCode(for:)`), or `exit(exitCode(for: classified))` directly.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #253: fix(args): --retry optional argument swallows a numeric first prompt word

## Summary
`apfel --retry 7 dwarfs and snow white` sets retryCount=7 and the prompt becomes "dwarfs and snow white" — the leading number is eaten. Verified via `--count-tokens`: `--retry 7 dwarfs` → prompt=1 token; `--retry seven dwarfs` → prompt=3. Silent prompt corruption, no error.

## Root cause
`Sources/CLI/CLIArguments.swift:454ff` — `case "--retry": if i+1 < args.count, let n = Int(args[i+1]) { result.retryCount = n; i += 1 }`.

## Suggested fix
Only consume an attached value (`--retry=N`) or add `--retry-count <n>`; at minimum only treat the next token as the count when a subsequent non-flag token still exists, and document the ambiguity in help + man.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #254: fix(env): invalid APFEL_* environment values are silently ignored while equivalent flags hard-error

## Summary
Invalid env values are silently dropped to defaults, while the equivalent flags exit 2. `APFEL_PORT=99999 apfel --serve` binds 11434 without a word; `APFEL_CONTEXT_STRATEGY=newest_first` (typo, underscore) silently uses the default. Verified: `APFEL_TEMPERATURE=abc APFEL_PORT=99999 APFEL_CONTEXT_STRATEGY=bogus apfel --count-tokens hi` → exit 0, no warning; `--port 99999` → exit 2.

## Root cause
`Sources/CLI/CLIArguments.swift:203-213` — `APFEL_PORT` out-of-range → silent 11434; `APFEL_TEMPERATURE` non-numeric/negative → silent nil; `APFEL_CONTEXT_STRATEGY` unknown → silent nil; same for `APFEL_MAX_TOKENS`, `APFEL_MCP_TIMEOUT`, `APFEL_CONTEXT_MAX_TURNS`, `APFEL_CONTEXT_OUTPUT_RESERVE`.

## Suggested fix
Have `parse()` collect env-validation warnings (e.g. a `[String]` of "ignoring APFEL_PORT=99999 (not in 1-65535)") on the returned struct; main.swift prints them to stderr unless `--quiet`. Keeps `parse()` pure and testable.

## Severity
Medium (individually low, systematic).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #255: fix(args): tokens after the first positional are silently swallowed into the prompt, including valid flags

## Summary
`apfel summarize this --output json` makes the prompt literally `"summarize this --output json"` and output stays plain — the flag is treated as prompt text. Verified: `apfel --count-tokens hello --output json` counted the flags as prompt (`prompt=4` tokens). No error, no warning.

## Root cause
`Sources/CLI/CLIArguments.swift:529` — `result.prompt = args[i...].joined(separator: " ")` in the `default:` arm.

## Suggested fix
After capturing the positional tail, scan it for tokens matching known flag spellings and emit a stderr warning ("flags after the prompt are treated as prompt text; put options before the prompt or use --"). Better (breaking): keep parsing flags after positionals and require `--` for dash-containing prompts (help already documents `--`).

## Severity
Medium-Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #256: fix(chat): no setlocale(LC_CTYPE, "") — libedit line editing is byte-wise for non-ASCII input

## Summary
apfel never calls `setlocale`, so it runs in the `"C"` locale regardless of the user's `LANG=…UTF-8`. libedit's multibyte handling (`ct_encode`/`mbrtowc`) depends on `LC_CTYPE`, so in `apfel --chat`, editing a line with `ü`/emoji (backspace, arrow-left, Ctrl-W) operates on single bytes — one backspace over `é` leaves a dangling `0xC3` byte and misdraws the line.

## Root cause
`grep -rn setlocale Sources/` → no hits. `Sources/CReadline/module.modulemap` links `edit` (libedit); `Sources/ChatLineEditor.swift:52-58` wraps `readline()`. The missing `setlocale` is a fact; the buffer-corruption effect is libedit's documented locale dependency (recommend interactive confirmation).

## Suggested fix
Call `setlocale(LC_CTYPE, "")` once at startup in `main.swift`, before `ChatLineEditor` is constructed.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #257: docs(help): --help ENVIRONMENT section drifts from the man page and parser

## Summary
Two drifts between `--help` (`Sources/CLI.swift:640-654`), the man page, and the parser:
1. `APFEL_MCP_TOKEN` is parsed and referenced in the `--mcp-token` help line ("prefer APFEL_MCP_TOKEN env") but missing from help's ENVIRONMENT list (the man page has it).
2. Help says `APFEL_MCP  MCP server paths (colon-separated)` while the parser's doc comment declares commas canonical and colons legacy-only (colons break `https://host:8080` URLs; `parseMCPServerPaths` has URL-reassembly heuristics to compensate).

## Suggested fix
Add `APFEL_MCP_TOKEN   Bearer token for remote MCP servers` to `printUsage()` and reword the `APFEL_MCP` line to "comma-separated (colon accepted for local paths)".

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #258: fix(output): NO_COLOR="" (empty) disables color, contradicting the spec and the man page

## Summary
`NO_COLOR=` (empty string, e.g. from `env -i NO_COLOR=` or a CI template) disables color, but no-color.org and apfel's own man page say only a **non-empty** value counts.

## Root cause
`Sources/Output.swift:16` — `let noColorEnv = ProcessInfo.processInfo.environment["NO_COLOR"] != nil`.

## Suggested fix
`environment["NO_COLOR"].map { !$0.isEmpty } ?? false`.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #259: feat(cli): shell completions, persistent chat history, and trailing newline on JSON output

## Summary
Three power-user UX gaps:
1. **No shell completions** — with ~40 flags and 5 context strategies, tab completion is high value; Homebrew installs completions natively. (`git ls-files | grep -i completion` → none.)
2. **No persistent chat history** — `Sources/ChatLineEditor.swift:21-22` uses only in-memory history (`using_history()`/`stifle_history(500)`, `clear_history()` in deinit); history resets every session.
3. **JSON outputs lack a trailing newline** — `CLI.swift:70`, `:193`, `Benchmark.swift:42` print with `terminator: ""` (last byte of `apfel --count-tokens -o json hi` is `}`), making `read`-loop / `wc -l` consumption awkward.

## Suggested fix
- Ship `completions/apfel.{bash,zsh,fish}` generated from the parser's flag table; install via the formula.
- Add opt-in history persistence (`read_history`/`append_history` guarded by `APFEL_HISTFILE` or a default path, skipped in `--quiet`).
- Print `\n` after final JSON objects (JSONL chat lines already have it).

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #260: fix(update): performUpdate hardcodes /opt/homebrew paths — breaks on non-default brew prefixes

## Summary
`apfel --update` hardcodes `/opt/homebrew/bin/{brew,apfel}`. On an Apple-Silicon Homebrew at a non-default prefix (e.g. `~/homebrew`), `detectInstallMethod` correctly returns `.homebrew` (path contains `/homebrew/Cellar/apfel/`), but the update runs `/opt/homebrew/bin/brew` which doesn't exist → "Could not check for updates."; and the post-upgrade version echo runs the wrong/absent binary → prints "Updated to " with empty version.

## Root cause
`Sources/CLI.swift:497` `shellOutput("/opt/homebrew/bin/brew", ...)`, `:531`, `:533` `shellOutput("/opt/homebrew/bin/apfel", ["--version"])`.

## Suggested fix
Derive the brew prefix from the resolved binary path (component before `/Cellar/` or `/opt/`), or locate `brew` via `PATH`; reuse the same prefix for the post-upgrade `apfel --version` echo.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #261: ci: per-PR CI never exercises the HTTP server, though model-free server suites exist and run on GH runners

## Summary
Per-PR CI never starts the HTTP server, so CORS/origin wiring, auth middleware, `/health`, 501s, and OpenAPI shape are unchecked. A PR that breaks `SecurityMiddleware.swift` merges green.

## Evidence
- `Package.swift` `apfel-tests` depends only on `ApfelCore` + `ApfelCLI`, so the unit suite cannot touch any root-level `Sources/*.swift` — zero unit coverage for `Server.swift`, `Handlers.swift` (1085 L), `SSE.swift`, `SecurityMiddleware.swift`, `Session.swift`, `ContextManager.swift`, `MCPClient.swift`, `TokenCounter.swift`, `SchemaConverter.swift`, and more.
- `.github/workflows/ci.yml:41-54` runs only a `-k` subset of `cli_e2e_test.py` + `test_man_page.py` — no server started.
- Yet `publish-release.yml:97-103` runs `security_test.py` + `openapi_spec_test.py` on the same runner image with the comment "no Apple Intelligence needed" (succeeded in April runs).

## Suggested fix
In `ci.yml`, after `make build`, start the two servers (reuse the `Makefile:211-217` block with the FATAL readiness check) and run `security_test.py` + `openapi_spec_test.py` (+ the structural subset of `mcp_remote_test`).

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #262: docs(ci): "GitHub runners are Intel" is false — runners are arm64

## Summary
Three places claim GitHub runners are Intel; they are arm64. The real constraint is Apple Intelligence being unavailable in virtualized runners, not architecture — the false premise wrongly implies CI can't build/package the arm64 artifact or run arm64-only checks (relevant to moving signing/packaging into CI).

## Evidence
`.github/workflows/ci.yml:43` ("GitHub-hosted macos-26 runners are Intel..."), CLAUDE.md CI section, `docs/release.md`. The 2026-06-25 main CI run log shows `Image: macos-26-arm64`.

## Suggested fix
Correct the three comments to "arm64 VMs without Apple Intelligence"; re-evaluate which release steps can be CI-hosted.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #263: docs(changelog): [Unreleased] discipline not enforced — features ship with empty changelog sections

## Summary
The Keep-a-Changelog flow (#201) relies on devs adding `[Unreleased]` entries, but `stamp-changelog.sh` happily stamps an empty section. This already happened: v1.6.1 shipped with an empty section, backfilled afterward in `7e56f5f`. The `-f` extraction feature (`05e8837`) touched no CHANGELOG line, so the next `make release` will publish it under an empty heading.

## Root cause
`scripts/stamp-changelog.sh:29-45` — no check that `[Unreleased]` has content.

## Suggested fix
In `stamp-changelog.sh`, exit 1 if the `[Unreleased]` section has no content lines; add a preflight ("commits since last tag exist but [Unreleased] is empty → FAIL"). Add the missing `-f` entry now.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #264: test(perf): performance_test asserts wall-clock speedup ratios > 1.0 — a known release-blocking flake class

## Summary
Five benchmarks still gate on `assert entry["speedup_ratio"] > 1.0` (trim_newest_first, trim_oldest_first, tool_schema_convert, request_body_capture_disabled, stream_debug_capture_disabled). The project already de-flaked `message_text_content` for exactly this reason (commit `02592b7`, CHANGELOG 1.6.1). On a loaded release machine these abort `make release` mid-flight (after version bump, before tag) on scheduler noise.

## Root cause
`Tests/integration/performance_test.py:24-36`.

## Suggested fix
For the algorithmic wins, assert against a minimum ratio on the **median** of repeated runs with a noise margin, or assert the algorithmic property (e.g. comparison count) instead of wall clock; keep the `validated is True` output-correctness assertions.

## Severity
Medium.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #265: test(integration): test_175 is a permanent no-op counted in the test total; stale RedTDD "deliberately failing" headers

## Summary
`Tests/integration/test_tdd_red.py:226-248` has a body of literally `pass` (docstring: "stays GREEN; it can never deterministically reach the overflow path") yet is counted in the advertised "301 integration tests" — a test that cannot fail inflates the count and gives false coverage signal. Separately, `Tests/apfelTests/RedTDDTests.swift:1-13` and `test_tdd_red.py:1-26` carry "DELIBERATELY FAILING... Do not 'fix' the code" headers for tickets #177/#178/#180/#181/#183 and #167-#183 — all now closed/fixed — which can mislead contributors triaging failures. `Tests/apfelTests/StreamCleanupTests.swift:66` is `try assertTrue(true)`.

## Suggested fix
Delete `test_175_...` (or convert it to assert the unit seam's presence like test_179 does); rewrite both RedTDD file headers to state the tickets are fixed and these are now regression guards.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #266: ci: -k name-substring allowlist in ci.yml erodes silently on test renames

## Summary
`.github/workflows/ci.yml:48-50` selects model-free tests via a 17-term `-k` substring list. pytest does not error when a `-k` term matches nothing, so renaming `test_update_flag` silently drops it from CI while staying green; new model-free tests are also not auto-included.

## Suggested fix
Add `@pytest.mark.model` to model-dependent tests and run `pytest Tests/integration/cli_e2e_test.py -m "not model"` with `--strict-markers`.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #267: docs: broken relative link in tool-calling guide

## Summary
`docs/tool-calling-guide.md:12` — `[docs/cli-reference.md](docs/cli-reference.md)` resolves to `docs/docs/cli-reference.md` (404 on GitHub). Only broken relative link across all `*.md` (scripted check).

## Suggested fix
Change the target to `](cli-reference.md)`.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #268: test(scripts): Tests/integration/run_tests.sh is a stale orphan with an explicit file list

## Summary
`Tests/integration/run_tests.sh:80-87` lists 6 suites explicitly, omitting `openapi_conformance_test.py`, `mcp_remote_test.py`, `test_chat.py`, and every `test_*.py` helper — contradicting the project rule "Release scripts use directory discovery, not explicit file lists". It is referenced nowhere (zero grep hits across README/docs/CLAUDE/Makefile/scripts). A dev using it believes they ran "the integration tests" while ~40% never execute.

## Suggested fix
Delete it, or replace the invocation with `python3 -m pytest Tests/integration/ -v --tb=short`.

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #269: fix(release): prev-tag selection uses substring grep -v; release-notes range excludes wrong tags

## Summary
`scripts/publish-release.sh:116` and `.github/workflows/publish-release.yml:134` compute the previous tag with `git tag --sort=-v:refname | grep -v "v$version" | head -1`. The pattern is unanchored and dot-unescaped: re-publishing v1.6.1 when v1.6.10+ exist filters those out too, so the release-notes commit range is wrong.

## Suggested fix
`grep -Fxv "v$version"` (fixed-string, whole-line).

## Severity
Low (one-char fix).

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

## Issue #270: docs(release): docs/release.md and CLAUDE.md numbers drifted from the scripts and reality

## Summary
Several stale numbers/steps:
- `docs/release.md` "What the release script does" step 6 omits `CHANGELOG.md`/`stamp-changelog.sh` (script lines 100-102) and the whole nixpkgs step (158-169).
- CLAUDE.md CI section: "~600 unit tests" vs the same file's "687"; "21 model-free integration tests" vs ~31 `-k`-matched + 8 man-page tests actually run; "Total: ~387" is arithmetically impossible with its own numbers; "~199 integration tests" vs ~262.
- Verified-accurate counts at v1.6.1: 294 `def test_` + 7 parametrize expansions = 301 integration; ~655 literal unit `test("` + locale-loop expansion ≈ 687 unit.

## Suggested fix
Correct the three stale CI-section numbers in CLAUDE.md and sync `docs/release.md` steps 6-9 with the actual script (CHANGELOG stamp + nixpkgs bump).

## Severity
Low.

---
_Filed from a full read-only audit of apfel v1.6.1 (server, CLI/chat, MCP/tool-calling, security, concurrency, tests/CI/docs). Findings verified against committed code; high-severity crash/DoS items were reproduced against the release binary. One issue per finding._

---

