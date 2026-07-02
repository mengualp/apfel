# Task 3 report — streaming SSE protocol defects (#223, #224)

Status: DONE
Branch: main (not pushed)
Commits:
- #223: `92156bb` fix(server): fence-strip json_object output on the streaming SSE path (#223)
- #224: `55aefb9` fix(server): stop streamed tool calls leaking as content; split finish chunk (#224)

Both fixes are in `Sources/Handlers.swift` on the plain streaming path (`streamingResponse`). The MCP-injected streaming path (`mcpAutoExecuteResponse`) already buffers fully and was left untouched.

---

## Issue #223 — json_object streaming delivered fenced (invalid) JSON

Root cause confirmed: YES. `streamingResponse` had no `jsonMode` argument and streamed raw suffix deltas verbatim; `JSONFenceStripper.strip` was only applied on the non-streaming (`:425`) and MCP (`:305`) paths. With `response_format json_object` the model emits a ```` ```json ```` fence, so the first delta was ```` "```json\n{\n  \"" ```` and the concatenated stream was invalid JSON.

Fix: thread `jsonMode` into `streamingResponse`. In json_object mode the loop buffers the whole response (a fence cannot be stripped from an incremental suffix because the closing ```` ``` ```` only arrives at the end) and emits one `JSONFenceStripper.strip(prev)` content delta after the stream completes, mirroring the structured-output streaming path (`Handlers.swift:839-854`). Completion tokens now count the delivered (stripped) content.

Files changed:
- `Sources/Handlers.swift` — `jsonMode` param + buffered stripped-delta emission
- `Tests/integration/openai_client_test.py` — `test_streaming_json_mode_valid_json`
- `CHANGELOG.md` — Fixed bullet

Red evidence (pre-fix, debug binary, scratch port 11499):
```
data: {"choices":[{"delta":{"content":"```json\n{\n  \"answer\":"},...
data: {"choices":[{"delta":{"content":" 42\n}\n```"},...
```
(first content delta is a fence; joined stream = invalid JSON)

Green evidence (post-fix, port 11499):
```
data: {"choices":[{"delta":{"role":"assistant"},...
data: {"choices":[{"delta":{"content":"{\n  \"answer\": 42\n}"},"finish_reason":null,...
data: {"choices":[{"delta":{},"finish_reason":"stop",...
data: [DONE]
```
Single content delta, valid parseable JSON, no fence.

---

## Issue #224 — streamed tool calls leaked as content; finish_reason bundled

Root cause confirmed: YES. On `stream:true` with client tools, the loop forwarded every model delta as `delta.content` and only ran `ToolCallHandler.detectToolCall` after the stream ended, so clients received the raw tool-call JSON as assistant text AND then a `tool_calls` chunk that also carried `finish_reason` in the same `ChunkChoice`.

Fix: thread `hasTools` into `streamingResponse`. While tools are in play the loop holds back content that is still a plausible tool-call prefix and flushes it as content only once it diverges (plain-text answers still stream token-by-token; tool-call output is buffered). On detection the `tool_calls` delta is emitted in its own chunk with `finish_reason: null`, followed by a SEPARATE empty-delta chunk carrying `finish_reason: "tool_calls"`.

Pure decision logic: `Sources/Core/StreamingToolCallGate.swift` — `isPlausibleToolCallPrefix(_:)`. Holds on empty/whitespace, a (partial) ```` ``` ```` fence, or a (partial) `{"tool_calls"` opener; flushes on anything else (prose, `{"answer"...`, arrays, mid-text fences). Unit-tested (15 cases) in `Tests/apfelTests/StreamingToolCallGateTests.swift`, registered in `main.swift`.

Files changed:
- `Sources/Core/StreamingToolCallGate.swift` (new)
- `Tests/apfelTests/StreamingToolCallGateTests.swift` (new) + `Tests/apfelTests/main.swift`
- `Sources/Handlers.swift` — `hasTools` param, gate wiring, split tool/finish chunks
- `Tests/integration/openai_client_test.py` — `test_streaming_tool_call_no_content_leak`
- `CHANGELOG.md` — Fixed bullet

Red evidence (pre-fix, port 11499):
```
data: {"choices":[{"delta":{"content":"{\"tool_calls\": [{\"id\":"},...     <- raw JSON leaked as content
... (5 content chunks of raw tool-call JSON) ...
data: {"choices":[{"delta":{"tool_calls":[...]},"finish_reason":"tool_calls",...  <- bundled finish_reason
```

Green evidence (post-fix, port 11499, forced tool call):
```
data: {"choices":[{"delta":{"role":"assistant"},...
data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"city\": \"Vienna\"}","name":"get_weather"},"id":"call_1","index":0,"type":"function"}]},"finish_reason":null,...
data: {"choices":[{"delta":{},"finish_reason":"tool_calls",...            <- separate finish chunk
data: [DONE]
```
No content leak; tool_calls in own chunk (finish_reason null); finish_reason in a separate empty-delta chunk.

Non-degradation check (tools present, plain-text answer) — still streams multiple content deltas:
```
"In a small, quiet town, a golden ret" / "riever named Max..." / " return each evening..." (7 content deltas) -> finish_reason: stop
```

---

## Test summary

- Unit: `swift run apfel-tests` = 734 passed (was 719; +15 StreamingToolCallGate cases). 0 failures.
- Build: `swift build` clean, zero warnings.
- Integration (model-dependent, NOT run by me as a pytest run against 11434 — verified manually via curl on scratch 11499 instead; controller should run at milestone):
  - `test_streaming_json_mode_valid_json` (#223) — added, verified equivalent behavior manually.
  - `test_streaming_tool_call_no_content_leak` (#224) — added, verified equivalent behavior manually.

## Concerns

- Residual edge (accepted per issue): if the model emits non-tool prose BEFORE a fenced/bare tool call (e.g. "Sure:\n```json{tool_calls...}```"), the gate flushes the prose immediately, so the later tool-call text would still stream as content while `detectToolCall` also fires at the end. With forced `tool_choice` the model emits a bare tool call (no preamble), so this does not occur in practice; the alternative (full buffering when tools are in play) was rejected because it would degrade legitimate plain-text streaming, which the issue explicitly forbids.
- The two new pytest tests are model-dependent and were validated by manual curl transcripts (model is available on this machine), not by a pytest run against the externally-managed 11434 server. The controller should include them in the milestone integration run.
