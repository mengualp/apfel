# Task 4 report — JSON-Schema conversion fixes (#219, #243, #247)

Status: DONE
Branch: main (not pushed). Working tree clean apart from the untracked `.superpowers/` dir.

Three commits, one per issue, in the required order:

- `25aae7f` fix(schema): parse nullable anyOf/oneOf/type-arrays; throw on other unions (#219)
- `0c1de28` fix(schema): split IR integer/number so json_schema "number" allows fractions (#243)
- `7bee8b9` perf(schema): make SchemaConversionCache an LRU that evicts one entry (#247)

Full unit suite green after each commit; final: **755 unit tests passed, 0 warnings** (`swift build` clean, `swift run apfel-tests`). New integration tests py-compile clean and are wired into `Tests/integration/test_tdd_red.py` for the controller to run at the model milestone.

---

## Issue #219 — anyOf/oneOf/type-arrays silently degrade to empty object

Root cause confirmed: YES. `SchemaParser.parseObject` read `schema["type"] as? String ?? "object"`, so any node without a scalar `type` (anyOf/oneOf/allOf, or `type` array) became an empty `object`, producing native tool defs with empty params and accepting union `json_schema` with 200 + unconstrained generation.

Files changed:
- `Sources/Core/SchemaParser.swift` — added `normalizeUnion(_:)`. Unwraps the supported nullable patterns (anyOf/oneOf `[X,{type:null}]` in any order; two-element `type:["<t>","null"]` in any order) to the non-null branch and reports nullability. A nullable property is forced optional regardless of the `required` list. Every other union (`allOf`, multi-type unions, type arrays without exactly one `null`) throws `Error.unsupportedType`. `parseObject` now normalizes at entry and reads `properties`/`enum`/`items`/`required` from the normalized node.
- `Tests/apfelTests/SchemaParserTests.swift` — 11 new unit tests (unwrap both orders, oneOf, type-array, enum preservation, nullable-optional even when required, and the throw cases: two non-null anyOf, allOf, 3-entry type array, type array without null).
- `Tests/integration/test_tdd_red.py` — `test_219_json_schema_unsupported_union_returns_400` (server-only, 400 + invalid_request_error) and `test_219_json_schema_nullable_property_conforms` (model-dependent, 200 + conforming).

Red evidence: 12 unit tests failed for the right reason (`got object(name:..., properties: [])` and `expected throw`) before the fix; green after.

Both consequences locked: parser now throws for unsupported unions (drives the existing `convertUncached` catch -> `fallback` text-injection for tools, and `generationSchema` rethrow -> 400 for json_schema); the two integration tests assert the 400 and the nullable-accept paths at the wire.

## Issue #243 — json_schema "number" generated as Int

Root cause confirmed: YES. `SchemaIR` conflated `integer`+`number` in one `.number` case; `SchemaConverter.dynamicSchema` mapped it to `DynamicGenerationSchema(type: Int.self)`, so fractional structured output was unreachable.

Files changed:
- `Sources/Core/SchemaIR.swift` — split `.number` into `.integer(name:description:)` and `.number(name:description:)`.
- `Sources/Core/SchemaParser.swift` — `"integer"` -> `.integer`, `"number"` -> `.number`.
- `Sources/SchemaConverter.swift` — the only exhaustive IR switch (`dynamicSchema`): `.integer` -> `Int.self`, `.number` -> `Double.self`. (Checked: no other switch over `SchemaIR` exists — grep for `case .array` finds only this site.)
- `Tests/apfelTests/SchemaParserTests.swift` — integer primitive now asserts `.integer`; new "integer and number parse to distinct IR cases"; nullable tests using integer updated to `.integer`.
- `Tests/integration/test_tdd_red.py` — `test_243_json_schema_number_allows_fractional` (model-dependent; asserts a `number` property yields a `float` that is not a whole number, price 9.99 prompt).

Red evidence: the retargeted integer test and the distinct-cases test failed before the split; green after.

## Issue #247 — SchemaConversionCache wipes entire cache when full

Root cause confirmed: YES. `insert` did `entries.removeAll(keepingCapacity: true)` at the 64-cap.

Files changed:
- `Sources/Core/LRUCache.swift` (new) — pure generic `LRUCache<Key: Hashable, Value>`: dictionary + order array (front = LRU). Reads (`value(forKey:)`) and writes (`insert(_:forKey:)`) refresh recency; at capacity a new key evicts only the front (LRU). FoundationModels-free, so unit-testable.
- `Sources/SchemaConverter.swift` — `SchemaConversionCache` now wraps `LRUCache<[ToolSignature], CachedSchemaConversion>(capacity: 64)`.
- `Tests/apfelTests/LRUCacheTests.swift` (new) + registered in `Tests/apfelTests/main.swift` — 9 tests including "full cache evicts exactly one LRU entry, not everything", "reading an entry marks it MRU so it survives eviction", "hot entry survives repeated cold churn", recency-refresh-on-update, and capacity-1.

Red evidence: LRUCache is a new pure component; its tests encode the correct eviction behavior and fail against the old `removeAll` semantics (capacity-3 + 4th insert would leave `count == 1`, tripping the `count == 3` and hot-survives assertions). Green against the new impl.

## Concerns

- The #247 LRU test/impl were authored together rather than strictly test-first-then-code; the tests still genuinely encode behavior the old `removeAll` cache fails. Everything else followed red-to-green.
- The three new model-dependent integration cases (#219 nullable-conforms, #243 fractional-number) are only exercised at the controller's model milestone; I ran the model-free unit suite and the 400-path integration test is server-only (not run here since servers on 11434 are controller-owned). #243's fractional assertion depends on the on-device 3B model actually emitting a non-integer for the price prompt — if it rounds, that test may be flaky; the schema now permits fractions, which is the fix under test.
