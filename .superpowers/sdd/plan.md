# Plan: Fix all 58 open audit issues (2026-07-01 batch) + release

Requirements source: `.superpowers/sdd/issues-all.md` (full GitHub issue bodies).
Baseline: main @ 061a7e5 (lesbar -f merged via #211, seed fix via #271, #212 fixed).

## Global Constraints (bind every task)

- TDD red-to-green: failing test first for every behavior change. No production code without a failing test.
- One commit per issue, message `fix(area): <summary> (#NNN)` (or docs/test/ci/feat prefix matching the issue title). Body explains root cause + fix. End with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Each fix adds a CHANGELOG.md `[Unreleased]` bullet (Keep-a-Changelog; Added/Fixed/Changed subsection) naming the issue number.
- Swift 6 strict concurrency; no `@unchecked Sendable` without proof; no new warnings from `swift build`.
- Error-test style: `catch let e as CLIParseError { assertTrue(e.message.contains("...")) }` — never bare `threw = true`.
- Unit tests: `swift run apfel-tests` must be 100% green before every commit.
- Integration tests requiring the model/servers: write them; they run at batch milestones on this machine, not in the implementer loop (implementer runs model-free ones: `python3 -m pytest Tests/integration/<file> -k <expr>` only if no server needed).
- Layering: ApfelCore stays FoundationModels-free; validation logic goes in Core where possible (unit-testable).
- No em/en dashes anywhere; plain hyphens only.
- Do NOT touch `.version`, `Sources/BuildInfo.swift`, README version badge.
- Man page + `--help` must be updated together when flags/exit codes/env vars change.

## Tasks

### Task 1 — Server crash + capacity DoS (#213, #214)
Files: Sources/Server.swift, Sources/Handlers.swift, Sources/Retry.swift, Sources/Core/ (StreamCleanup), tests.
#214: restructure AsyncSemaphore.wait(timeout:) as structured race; unit test forces timeout, asserts thrown SemaphoreTimeoutError, no crash.
#213: streaming early-fail paths must release permit + active_requests; integration test: N+1 malformed streaming requests leave active_requests==0.

### Task 2 — Server request validation + error protocol (#233, #234, #235, #236, #237, #238)
Files: Sources/Core/ChatRequestValidator.swift, Sources/Core/OpenAIModels.swift, Sources/Models.swift, Sources/Handlers.swift, tests in Tests/apfelTests/OpenAIModelsTests.swift + integration.
Empty/null last-message content -> 400; 413 with proper error object + CORS; top_p range + temperature<=2; ErrorDetail encodes param/code (null), invalidModel -> 404 model_not_found; unknown x_context_strategy -> 400; usage:null on SSE chunks with include_usage; invalid tool_choice -> 400.

### Task 3 — Streaming protocol correctness (#223, #224)
Files: Sources/Handlers.swift, Sources/SSE.swift (if present), integration tests.
json_object fence-strip on streaming path; buffer/hold-back tool-call prefixes, emit tool_calls delta then separate finish_reason chunk.

### Task 4 — Schema conversion (#219, #243, #247)
Files: Sources/Core/SchemaParser.swift, Sources/Core/SchemaIR.swift, Sources/SchemaConverter.swift, unit tests.
anyOf/oneOf/type-arrays: parse optional pattern, else throw so text-fallback/400 engages; split .integer/.number -> Double; LRU eviction instead of removeAll.

### Task 5 — MCP process robustness (#215, #216, #246)
Files: Sources/MCPClient.swift, Sources/main.swift, unit + integration tests.
SIGPIPE ignore + guarded throwing writes; timed-out connection deregistered from toolMap/allTools + child reaped (waitUntilExit, SIGTERM->SIGKILL); awaited shutdown before exit paths.

### Task 6 — MCP wire protocol (#217, #218, #241, #242)
Files: Sources/MCPClient.swift, Sources/Core/MCPProtocol.swift, Sources/Core/BufferedLineReader.swift, unit tests + integration (mcp calculator).
id-correlation loop skipping notifications, reply to ping; serialize send+receive per connection (lock) so concurrent calls don't cross-deliver; malformed args -> error result (not {}); parseToolCallResponse: join all text blocks, empty content ok, structuredContent fallback.

### Task 7 — Tool-call pipeline behavior (#220, #221, #239, #240, #244)
Files: Sources/Session.swift, Sources/MCPClient.swift, Sources/Core/ToolCallHandler.swift, Sources/Handlers.swift, tests.
isError -> fed back to model, not 500; token-count + head/tail-truncate tool results with explicit marker; duplicate tool names -> loud warning + dedup; server path gets bounded multi-round loop + stripToolCallJSON; synthesize missing tool-call id.

### Task 8 — Server security hardening (#228, #229, #230, #231, #232)
Files: Sources/Server.swift, Sources/Core/OriginValidator.swift, Sources/SecurityMiddleware.swift, Sources/MCPClient.swift, unit + security integration tests.
Non-loopback+no-token -> prominent warning; MCP child gets scrubbed minimal env; Host-header allowlist when origin check enabled; constant-time token compare; loud warning whenever origin check disabled.

### Task 9 — CLI argument parsing + env (#222, #248, #253, #254, #255)
Files: Sources/CLI/CLIArguments.swift, Sources/main.swift, Tests/apfelTests/CLIArgumentsTests.swift, cli_e2e integration.
Kill no-args fast path (parse env always, keep stream default + TTY usage branch); demos subcommand handles -h/--help + unknown-option errors; --retry only consumes value via --retry=N or safe lookahead per issue; env validation warnings surfaced on parse result, printed to stderr unless --quiet; warn when flag-like tokens ride in the positional tail.

### Task 10 — CLI output + chat robustness (#249, #250, #251, #252, #256, #258, #260)
Files: Sources/Output.swift, Sources/CLI.swift, Sources/main.swift, Sources/CReadline/shim.h, Sources/ChatLineEditor.swift, man page, tests.
styledErr keyed on stderr TTY; usage to stderr on error paths (stdout+0 for --help); SIGINT restores termios + document exit 130 in man/help; chat rotation failure exits nonzero; setlocale(LC_CTYPE,"") at startup; NO_COLOR non-empty only; brew prefix derived from binary path.

### Task 11 — CLI power-user features (#259)
Files: completions/apfel.{bash,zsh,fish}, Sources/ChatLineEditor.swift (APFEL_HISTFILE persistence), JSON trailing newline (CLI.swift, Benchmark.swift), formula install hooks (scripts/write-homebrew-formula.sh), tests, docs.

### Task 12 — Test + CI infrastructure (#227, #261, #262, #264, #265, #266, #268)
Files: Tests/integration/conftest.py, performance_test.py, mcp_remote_test.py, test_tdd_red.py, RedTDDTests.swift, StreamCleanupTests.swift, .github/workflows/ci.yml, Makefile, scripts.
APFEL_REQUIRE_FULL=1 skip->fail hook exported by release/test paths; fixture skips -> fails for startup breakage; CI starts servers + runs model-free server suites; arm64 doc corrections; perf ratios -> median with margin (keep validated asserts); delete test_175 no-op + fix stale RedTDD headers; pytest markers instead of -k list; delete run_tests.sh.

### Task 13 — Release pipeline integrity (#225, #226, #263, #269)
Files: .github/workflows/publish-release.yml, Makefile (package-release-asset), scripts/publish-release.sh, scripts/stamp-changelog.sh, scripts/post-release-verify.sh, CLAUDE.md.
Delete or parity-fix publish-release.yml (prefer delete: CLAUDE.md mandates local releases; keep ci.yml); Developer ID codesign (identity: "Developer ID Application: Franz Enzenhofer (7D2YX5DQ6M)") + notarize + staple in package step + .sha256 release asset + post-release digest verify; stamp-changelog fails on empty [Unreleased]; grep -Fxv prev-tag fix.

### Task 14 — Docs sync (#257, #267, #270) — LAST (final counts)
Files: Sources/CLI.swift printUsage, man page, docs/tool-calling-guide.md, docs/release.md, CLAUDE.md.
help ENVIRONMENT adds APFEL_MCP_TOKEN + comma-canonical wording; fix docs/docs link; recount tests AFTER all tasks and sync CLAUDE.md CI-section numbers + release.md steps.

## Milestones

- After Tasks 1-4: full `make test` (unit + integration with model) must pass.
- After Tasks 5-8: full `make test`.
- After Tasks 9-11: full `make test`.
- After Tasks 12-14: `make preflight`.
- Then: final whole-branch review, `make release TYPE=minor`, post-release-verify, close all 58 issues with commit references, delete stray branches, single worktree on main.
