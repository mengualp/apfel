# Task 2 report - server request-validation / error-protocol fixes (#233-#238)

Branch: main. Six commits, one per issue, in issue-number order. Not pushed
(controller pushes). Build clean (zero warnings), 719 unit tests green,
12/12 new integration tests green against a scratch server on port 11499.

## Summary of results

| Issue | Root cause confirmed | Commit | Status |
|-------|----------------------|--------|--------|
| #233 | yes | 26428f2 | DONE |
| #234 | yes | efba474 | DONE |
| #235 | yes | 2d48f39 | DONE |
| #236 | yes | 3a11352 | DONE |
| #237 | yes | 02d322c | DONE |
| #238 | yes | 2efc149 | DONE |

---

## #233 - empty/null last message content -> 400 (commit 26428f2)

Root cause confirmed: `ChatRequestValidator` never checked that the final
non-tool message carried text; empty/null content passed validation and hit
`ContextManager.makeSession`'s `throw ApfelError.unknown("Last message has no
text content")`, which maps to HTTP 500.

Files changed:
- `Sources/Core/ChatRequestValidator.swift` - new `.emptyLastMessageContent`
  case + message/event strings + check (after image check; non-tool last
  message with nil/empty `textContent` -> 400). Tool-role last messages exempt
  (they use a synthetic prompt).
- `Tests/apfelTests/OpenAIModelsTests.swift` - 3 unit tests (empty string,
  null, tool-last-with-empty-content accepted).

No Handlers change needed (validation failures already return 400; #236 later
made it status-aware but this case stays 400).

Red evidence: without the validator check the empty/null-content requests
return `nil` from `validate()`, so the new tests (expecting
`.emptyLastMessageContent`) fail. Green: all pass.

## #234 - >1 MiB body -> 413 with error object + CORS + log (commit efba474)

Root cause confirmed: `request.body.collect(upTo:)` throws on an over-limit
body and the error propagated out of `handleChatCompletion`;
`SecurityMiddleware` only applies CORS to a returned (non-throwing) response,
and `Server.swift` only logs responses it receives - so the 413 had no error
object, no CORS headers, no log entry.

Files changed:
- `Sources/Handlers.swift` - wrap the `collect` in do/catch; on failure return
  `chatFailure(status: 413, type: "invalid_request_error")` so it flows back
  through CORS + logging.
- `Tests/integration/server_validation_test.py` (new) - 413 status + error
  object + CORS header for an allowed origin.

Verified live (scratch server + curl): 413, `{"error":{...}}`,
`Access-Control-Allow-Origin` echoed. Wire-level, so no unit test; integration
covers it (controller runs against 11434; I ran it against 11499).

## #235 - out-of-range top_p / temperature -> 400 (commit 2d48f39)

Root cause confirmed: only `temperature < 0` was checked; no `top_p` check.
Out-of-range values reached FoundationModels and surfaced as opaque 500s;
`temperature: 5.0` was accepted.

Files changed:
- `Sources/Core/ChatRequestValidator.swift` - `.invalidParameterValue` for
  `top_p` outside `0...1` and `temperature > 2` (existing `< 0` kept).
- `Tests/apfelTests/OpenAIModelsTests.swift` - 5 unit tests (temp>2, top_p>1,
  top_p<0, boundaries 0/1, temp==2).
- integration: top_p 2.0/-0.5 + temp 5.0 -> 400.

## #236 - error object param/code + unknown model 404 (commit 3a11352)

Root cause confirmed: `ErrorDetail`'s synthesized Encodable dropped nil
param/code; `invalidModel` routed to 400 with no code.

Files changed:
- `Sources/Models.swift` - `ErrorDetail.encode(to:)` emits `param`/`code` as
  explicit null when absent (mirrors the `Choice.logprobs` pattern).
- `Sources/Core/ChatRequestValidator.swift` - `ChatRequestValidationFailure`
  gains `httpStatusCode`/`errorCode`/`errorParam`; `invalidModel` ->
  404 / `model_not_found` / `model`, everything else 400/nil.
- `Sources/Handlers.swift` - route validation failures through those props;
  `openAIError` and `chatFailure` gained an optional `param`.
- `Tests/apfelTests/OpenAIModelsTests.swift` - 2 unit tests for the mapping.
- integration: unknown model -> 404 w/ code+param; empty messages -> 400 with
  explicit null param/code.

Verified live: 404 body with `code: model_not_found`, `param: model`; a plain
400 shows `param: null`, `code: null`. (ErrorDetail is in the root target, not
unit-testable; the mapping props are the unit-testable slice.)

## #237 - unknown x_context_strategy -> 400 (commit 02d322c)

Root cause confirmed: Handlers did
`x_context_strategy.flatMap { ContextStrategy(rawValue:) } ?? .newestFirst`,
silently swallowing typos.

Files changed:
- `Sources/Core/ChatRequestValidator.swift` - reject a non-nil value that does
  not map to a `ContextStrategy` case, listing valid raw values from
  `ContextStrategy.allCases`.
- `Tests/apfelTests/OpenAIModelsTests.swift` - reject-unknown (message lists
  values) + accept-every-valid-case.
- integration: `sliding-window-typo` -> 400 listing values.

Verified live: message = "'x_context_strategy' must be one of: newest-first,
oldest-first, sliding-window, summarize, strict. Got 'sliding-window-typo'."

## #238 - usage:null on non-final chunks; invalid tool_choice -> 400 (commit 2efc149)

Root cause confirmed for both parts.

(a) `ChatCompletionChunk`'s synthesized Encodable dropped nil `usage`.
- `Sources/Models.swift` - added `includeUsageNull` control flag + manual
  `encode(to:)` emitting explicit `usage: null` when opted in, omitting
  otherwise.
- `Sources/SSE.swift` - `sseRoleChunk`/`sseContentChunk`/`sseRefusalChunk`/
  `sseContentFilterFinishChunk` gained `includeUsage`.
- `Sources/Handlers.swift` - `includeUsage` plumbed to every non-final chunk
  on all four streaming paths (plain, structured, MCP auto-execute, refusal).

(b) `ToolChoice.init(from:)` coerced any unrecognized string/undecodable
object to `.auto`.
- `Sources/Core/OpenAIModels.swift` - new `.invalid(String)` case; `"auto"`
  now recognized explicitly; unrecognized string -> `.invalid(string)`,
  undecodable object -> `.invalid("<object>")`.
- `Sources/Core/ChatRequestValidator.swift` - rejects `.invalid` with 400.
- Tests: `OpenAIModelsTests` (unrecognized-string ->.invalid, auto-string,
  validator rejects string+object, accepts recognized), `ApfelCorePublicAPIUsageTests`
  (.invalid in the surface list), integration (invalid string/object -> 400,
  usage:null streaming, no-usage-key-without-opt-in).

Verified live: with `include_usage` every non-final chunk has `"usage":null`
and the single final `choices:[]` chunk carries real usage; without it no
`usage` key anywhere. Invalid tool_choice string/object -> 400.

### Tests updated to reflect NEW behavior (deliberate)
- `OpenAIWireFormatTests` "ToolChoice falls back to auto for empty object" ->
  renamed and now asserts `.invalid("<object>")` (was `.auto`). This was the
  one test locking the old silent-coercion behavior.
- `OpenAIModelsTests` "ToolChoice falls back to auto for unknown string" (it
  actually fed `"auto"`) split into an auto-string test + an unrecognized ->
  `.invalid` test.

## Concerns / notes

- `ErrorDetail` and `ChatCompletionChunk` live in the root `apfel` target
  (not linked into `apfel-tests`), so their encoders are covered by integration
  tests only (as the dispatch anticipated). The unit-testable slices (validator
  props, ToolChoice decoding) are covered in `OpenAIModelsTests`.
- New integration file `Tests/integration/server_validation_test.py` uses the
  existing session server on 11434 (model-free tests run in CI; the two
  `#238a` streaming tests are model-dependent - controller runs them). I ran
  all 12 against a scratch 11499 server: 12 passed.
- The `#238a` `usage:null` change touches four streaming paths; I plumbed
  every non-final chunk and grep-verified no bare SSE builder calls remain.
