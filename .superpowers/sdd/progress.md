# Progress Ledger — audit-batch fixes (plan: .superpowers/sdd/plan.md)

Baseline: main @ 061a7e5. PR #211 (lesbar -f) merged, PR #271 merged (fixes #212), PR #210 closed superseded.
Working directly on main; one commit per issue; push + close issues after each task's review passes.

## Task status
Task 1: complete (#214 cc02d5f, #213 5310075; 703/703 unit + 3 new integration green; controller diff-review clean)
Task 2: complete (#233 26428f2, #234 efba474, #235 2d48f39, #236 3a11352, #237 02d322c, #238 2efc149; 719/719 unit green; pushed; issues closed)
Task 3: complete (#223 92156bb, #224 55aefb9; 734/734 unit green; pushed; issues closed; model-dep pytest guards run at milestone)
Task 4: complete (#219 25aae7f, #243 0c1de28, #247 7bee8b9; 755/755 unit green; pushed; issues closed)
Milestone make test after Tasks 1-4: GREEN (344/344 integration, 755 unit) after stale-test fix bbcee11. Lesson: judge make test by the pytest summary line, tail masks exit codes.

## Minor findings parked for final review
- SemaphoreTimeoutError.errorDescription contains an em dash (pre-existing string moved from Retry.swift)
- test_stream_permit_release.py couples to default --max-concurrent 5 via documented constant
- #233 fix skips the empty-content check when last role is "tool"; an empty tool message may still 500 via makeSession (verify in final review)
- StreamingToolCallGate: fenced non-tool-call answers fully buffer while tools in play (accepted trade-off)
- em dashes crept into new Swift file headers (StreamingToolCallGate.swift etc.) - sweep before release
