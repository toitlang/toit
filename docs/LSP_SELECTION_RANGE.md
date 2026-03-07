# LSP `textDocument/selectionRange` — Implementation Plan

## Overview

The LSP [`textDocument/selectionRange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_selectionRange) feature provides "smart selection" — given cursor positions, it returns nested ranges of increasing syntactic scope. Editors use this for Expand/Shrink Selection (e.g., `Ctrl+Shift+→` in VS Code).

**Example:** cursor on `stringify` in `return x.stringify`:
1. `stringify` — identifier
2. `x.stringify` — dot expression / call
3. `return x.stringify` — return statement
4. method body block
5. entire method declaration
6. entire class declaration
7. entire file

## Architecture Decision

**The selection ranges must be computed in the C++ compiler**, because:

- SelectionRange is fundamentally about **syntactic nesting** — the tree structure of the AST.
- The AST (`ast::Node` hierarchy) lives in the C++ compiler and carries precise `selection_range()` and `full_range()` on every node.
- The Toit-side LSP server only has summaries (class/method level) — no expression-level structure.
- A text-heuristic approach would be a shortcut that produces inferior results.

**The feature does NOT use the `LspSelectionHandler` mechanism.** That mechanism is designed for "what does the identifier at the cursor resolve to?" (hover, goto-definition, completion, etc.). SelectionRange instead asks "what are all the syntactic containers around the cursor?" — it needs an AST tree walk, not name resolution.

**The feature does NOT require resolution or type-checking.** Only the parsed AST is needed. The implementation hooks into `Pipeline::run()` after `_parse_units()` but before `resolve()`, following the model set by `should_emit_semantic_tokens` — a flag on the `Lsp` object triggers the emission and early exit.

## Protocol Between C++ Compiler ↔ Toit Server

### Request (Toit → C++ via stdin)

```
SELECTION RANGE
<path>
<num_positions>
<line_0>    (0-based, converted to 1-based in compiler)
<col_0>     (0-based, converted to 1-based in compiler)
<line_1>
<col_1>
...
```

### Response (C++ → Toit via stdout)

For each position (in order):
```
<num_ranges>
<from_line_0> <from_col_0> <to_line_0> <to_col_0>    (innermost, 0-based)
<from_line_1> <from_col_1> <to_line_1> <to_col_1>    (next larger)
...
<from_line_N> <from_col_N> <to_line_N> <to_col_N>    (outermost)
```

Ranges are emitted **innermost-first** (smallest to largest). The Toit side constructs the linked list by folding from the end.

If no ranges are found for a position, `num_ranges` is `0`.

The protocol emits each range field on its own line (4 lines per range), consistent with `read-range` in `compiler.toit`.

## Implementation Steps

### Phase 1: C++ Compiler — AST Range Collection

#### 1.1 New protocol class: `LspSelectionRangeProtocol`

**File:** `src/compiler/lsp/protocol.h`

Add a new sub-protocol class alongside the existing ones:

```cpp
class LspSelectionRangeProtocol : public LspProtocolBase {
 public:
  using LspProtocolBase::LspProtocolBase;

  /// Emits the number of ranges for one position.
  void emit_range_count(int count);
  /// Emits a single range (4 lines: from_line, from_col, to_line, to_col).
  void emit_range(const LspRange& range);
};
```

Add the member to `LspProtocol` and its accessor.

**File:** `src/compiler/lsp/protocol.cc`

Implement the two methods — simple `printf` calls, identical in style to existing protocol methods.

#### 1.2 New AST visitor: `SelectionRangeCollector`

**File:** `src/compiler/lsp/selection_range.h`

```cpp
#pragma once

#include <vector>
#include "../ast.h"
#include "../sources.h"

namespace toit {
namespace compiler {

/// Collects all AST node ranges that contain a target position.
///
/// Walks the AST tree and records both `full_range()` and `selection_range()`
/// of every node whose range contains the target. After the walk, ranges are
/// sorted smallest-first (innermost) and deduplicated.
class SelectionRangeCollector : public ast::TraversingVisitor {
 public:
  explicit SelectionRangeCollector(Source::Range target) : target_(target) {}

  /// Returns the collected ranges, sorted from innermost to outermost.
  std::vector<Source::Range> collect(ast::Unit* unit);

 private:
  Source::Range target_;
  std::vector<Source::Range> ranges_;

  void check_and_add(ast::Node* node);

  // Override every node visitor to call check_and_add before delegating.
  // Uses the NODES macro to generate all overrides uniformly.
  #define DECLARE(name) void visit_##name(ast::name* node) override;
  NODES(DECLARE)
  #undef DECLARE
};

} // namespace compiler
} // namespace toit
```

**File:** `src/compiler/lsp/selection_range.cc`

The implementation:

- `check_and_add(node)`: If `node->full_range()` is valid and contains `target_`, push it. If `node->selection_range()` differs and also contains `target_`, push that too.
- Each `visit_*` override: calls `check_and_add(node)` then `TraversingVisitor::visit_*(node)` (to recurse into children).
  - **Exception**: override `visit_Import` and `visit_Export` to also recurse into their children (the base `TraversingVisitor` skips them, but we want import path segments for selection).
- `collect(unit)`: resets state, visits the unit, sorts ranges by `length()` ascending, deduplicates adjacent equal ranges, returns the result.

**Key design choice:** Using the `NODES(V)` macro to generate all overrides is idiomatic for the codebase and ensures new node types are automatically handled. Every override follows the same pattern:

```cpp
void SelectionRangeCollector::visit_Foo(ast::Foo* node) {
  check_and_add(node);
  TraversingVisitor::visit_Foo(node);
}
```

A production-quality implementation uses a macro to avoid error-prone repetition:

```cpp
#define OVERRIDE(name)                                                   \
void SelectionRangeCollector::visit_##name(ast::name* node) {            \
  check_and_add(node);                                                   \
  TraversingVisitor::visit_##name(node);                                 \
}
NODES(OVERRIDE)
#undef OVERRIDE
```

Some nodes may need specialized handling to provide richer ranges:
- **`Import`**: also visit segments/show-identifiers (the base `TraversingVisitor::visit_Import` is empty).
- **`Export`**: similarly visit its identifiers.
- **`LiteralStringInterpolation`**: ensure interpolation expressions and format strings are visited (already handled by `TraversingVisitor`, but verify ranges are correct).

#### 1.3 Hook into the Lsp class

**File:** `src/compiler/lsp/lsp.h`

Add state and methods to `Lsp`:

```cpp
// Selection-range state.
bool should_emit_selection_ranges() const { return should_emit_selection_ranges_; }
void set_selection_range_request(const char* path,
                                 const std::vector<std::pair<int,int>>& positions) {
  should_emit_selection_ranges_ = true;
  selection_range_path_ = path;
  selection_range_positions_ = positions;
}
/// Walks the AST units, finds the target file, and emits selection ranges.
/// Calls exit(0) after emitting.
void emit_selection_ranges(const std::vector<ast::Unit*>& units,
                           SourceManager* source_manager);
```

Private members:
```cpp
bool should_emit_selection_ranges_ = false;
const char* selection_range_path_ = null;
std::vector<std::pair<int,int>> selection_range_positions_;  // (line, col), 1-based
```

**File:** `src/compiler/lsp/lsp.cc` (new, or add to existing)

Implement `emit_selection_ranges`:
1. Find the `ast::Unit*` whose `absolute_path()` matches `selection_range_path_`.
2. For each position in `selection_range_positions_`:
   a. Convert (line, col) to a `Source::Position` using `SourceManager`.
   b. Create a `SelectionRangeCollector` with a point range at that position.
   c. Call `collector.collect(unit)` to get sorted ranges.
   d. Emit `num_ranges` then each range via `LspSelectionRangeProtocol`.
3. `exit(0)`.

#### 1.4 Hook into `Pipeline::run()`

**File:** `src/compiler/compiler.cc`

In `Pipeline::run()`, after the `parse_only` early-return and before `resolve()`:

```cpp
if (configuration_.parse_only) return Result::invalid();

// Selection-range: only needs the parsed AST, not resolution.
if (lsp() != null && lsp()->should_emit_selection_ranges()) {
  lsp()->emit_selection_ranges(units, source_manager());
  UNREACHABLE();
}

ir::Program* ir_program = resolve(units, ENTRY_UNIT_INDEX, CORE_UNIT_INDEX);
```

This is analogous to how `should_emit_semantic_tokens` works — a flag on `Lsp` triggers emission at the right pipeline stage. The difference is we hook in earlier (post-parse instead of post-resolve) since we don't need resolution.

#### 1.5 Command dispatch and pipeline function

**File:** `src/compiler/compiler.cc`

Add the dispatch case in `Compiler::language_server()`:

```cpp
} else if (strcmp("SELECTION RANGE", mode) == 0) {
  const char* path = reader.next("path");
  int position_count = reader.next_int("position count");
  std::vector<std::pair<int,int>> positions;
  positions.reserve(position_count);
  for (int i = 0; i < position_count; i++) {
    int line = 1 + reader.next_int("line number (0-based)");
    int col  = 1 + reader.next_int("column number (0-based)");
    positions.push_back({line, col});
  }
  NullDiagnostics diagnostics(&source_manager);
  configuration.diagnostics = &diagnostics;
  lsp_selection_range(path, positions, configuration);
}
```

This goes alongside the existing `SEMANTIC TOKENS` and `ANALYZE` blocks that don't use location-based pipelines.

Add the pipeline function:

```cpp
void Compiler::lsp_selection_range(const char* source_path,
                                   const std::vector<std::pair<int,int>>& positions,
                                   const PipelineConfiguration& configuration) {
  configuration.lsp->set_selection_range_request(source_path, positions);
  ASSERT(configuration.diagnostics != null);
  LanguageServerPipeline pipeline(LanguageServerPipeline::Kind::selection_range,
                                  configuration);
  pipeline.run(ListBuilder<const char*>::build(source_path), false);
}
```

Add `selection_range` to `LanguageServerPipeline::Kind`.

#### 1.6 CMakeLists.txt

**File:** `src/CMakeLists.txt`

Add `compiler/lsp/selection_range.cc` (and `selection_range.h`) to the source list.

#### 1.7 Position → Source::Range conversion

The `SourceManager` can convert file offsets to `Source::Position` values. We need to convert (line, column) to a `Source::Position` for the target file. The `SourceManager::compute_location(Source::Position)` goes the other direction (position→location).

For the reverse mapping (line,col → position), we need to scan the source text of the target file:
1. Get the `Source*` for the target file from its `ast::Unit` (via `unit->source()`).
2. Scan the source text to find the byte offset for (line, col).
3. Create `Source::Position::from_token(source->offset() + byte_offset)`.

This logic belongs in `emit_selection_ranges` in `lsp.cc`.

### Phase 2: Toit Server — Protocol Integration

#### 2.1 Protocol types

**File:** `tools/lsp/server/protocol/selection_range.toit` (new)

```toit
import .lsp-protocol show MapWrapper Range Position

class SelectionRangeParams extends MapWrapper:
  text-document -> Map: return map_["textDocument"]
  positions -> List: return map_["positions"]

  constructor json/Map:
    map_ = json
```

The `SelectionRange` response is built directly as a Map (consistent with other protocol responses):

```toit
// In server.toit or a helper:
// Build a SelectionRange linked-list from a list of ranges (innermost first).
build-selection-range ranges/List -> Map?:
  if ranges.is-empty: return null
  result := null
  // Fold from outermost to innermost.
  for i := ranges.size - 1; i >= 0; i--:
    entry := {:}
    entry["range"] = ranges[i].map_
    if result: entry["parent"] = result
    result = entry
  return result
```

#### 2.2 Compiler method

**File:** `tools/lsp/server/compiler.toit`

Add a `selection-range` method:

```toit
selection-range --project-uri/string? uri/string positions/List -> List:
  path := translator.to-path uri --to-compiler
  position-lines := positions.map: | pos/Map |
    "$pos["line"]\n$pos["character"]"
  input := "SELECTION RANGE\n$path\n$positions.size\n$(position-lines.join "\n")\n"
  run --project-uri=project-uri --compiler-input=input: | reader/io.Reader |
    results := []
    positions.size.repeat:
      count-line := reader.read-line
      if not count-line:
        results.add null
        return results  // Short-circuit on EOF.
      count := int.parse count-line
      ranges := []
      count.repeat:
        ranges.add (read-range reader)
      results.add ranges
    return results
  unreachable
```

#### 2.3 Server handler

**File:** `tools/lsp/server/server.toit`

Add to the `handlers` map:

```toit
"textDocument/selectionRange": (:: selection-range it),
```

Implement the method:

```toit
selection-range params/Map -> List:
  uri := translator.canonicalize params["textDocument"]["uri"]
  project-uri := documents_.project-uri-for --uri=uri --recompute
  positions := params["positions"]
  range-lists := compiler_.selection-range
      --project-uri=project-uri uri positions
  // Build SelectionRange linked lists from flat range lists.
  return range-lists.map: | ranges/List? |
    if not ranges or ranges.is-empty: null
    else: build-selection-range ranges
```

Where `build-selection-range` folds the flat list into nested `{"range": ..., "parent": ...}` maps.

#### 2.4 Server capabilities

**File:** `tools/lsp/server/protocol/server_capabilities.toit`

Add `--selection-range-provider /bool? = null` parameter to `ServerCapabilities` constructor. Add `map_["selectionRangeProvider"] = selection-range-provider` in the body.

**File:** `tools/lsp/server/server.toit`

In `initialize`, add `--selection-range-provider` to the `ServerCapabilities` construction:

```toit
server-capabilities := ServerCapabilities
    --completion-provider=...
    ...
    --selection-range-provider
```

#### 2.5 Client test method

**File:** `tools/lsp/server/client.toit`

```toit
send-selection-range-request --path/string positions/List -> any:
  return send-selection-range-request --uri=(to-uri path) positions

send-selection-range-request --uri/string positions/List -> any:
  result := connection_.request "textDocument/selectionRange" {
    "textDocument": {
      "uri": uri,
    },
    "positions": positions,
  }
  if always-wait-for-idle: wait-for-idle
  return result
```

### Phase 3: Tests

#### 3.1 Test runner

**File:** `tests/lsp/selection-range-test-runner.toit` (new)

The test format uses inline annotations. Each test position is marked with `^` in a comment, followed by expected ranges as `[from_line:from_col]-[to_line:to_col]` pairs, innermost first:

```toit
foo x/int -> string:
  return x.stringify
/*           ^
  [1:9]-[1:18]
  [1:2]-[1:18]
  [0:0]-[1:18]
*/
```

The test runner:
1. Parses the test file for `/*` + `^` markers.
2. For each marker, reads the expected range chain.
3. Sends a `selectionRange` request with that position.
4. Walks the response's `parent` chain and compares each range with expected.

#### 3.2 Test cases

**File:** `tests/lsp/basic-selection-range-test.toit` (new)

Test cases covering:
- Top-level functions: identifier → call → return → method body → method → file
- Class members: field name → field → class body → class → file
- Nested expressions: identifier → dot → call → binary → if condition → if → method body → method → class → file
- Literals: string → return → method body → ...
- Import statements: segment → import path → import → file
- Block/lambda: parameter → block body → block → call → ...
- Local variable declarations
- Parenthesized expressions
- String interpolations
- Try/finally blocks

#### 3.3 CMakeLists.txt

**File:** `tests/lsp/CMakeLists.txt`

Add glob and dispatch:

```cmake
file(GLOB TOIT_SELECTION_RANGE_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR}
    "*selection-range-test.toit" "*/*selection-range-test.toit"
    "*/*/*selection-range-test.toit" "*/*/*/*selection-range-test.toit")
```

Add to `ALL_TESTS`, add `elseif` branch for `TOIT_SELECTION_RANGE_TESTS` using `selection-range-test-runner.toit`.

## File Change Summary

### New Files
| File | Purpose |
|------|---------|
| `src/compiler/lsp/selection_range.h` | `SelectionRangeCollector` AST visitor |
| `src/compiler/lsp/selection_range.cc` | Visitor implementation |
| `tools/lsp/server/protocol/selection_range.toit` | LSP protocol types (params) |
| `tests/lsp/selection-range-test-runner.toit` | Test runner |
| `tests/lsp/basic-selection-range-test.toit` | Test cases |

### Modified Files
| File | Change |
|------|--------|
| `src/compiler/lsp/protocol.h` | Add `LspSelectionRangeProtocol` class, add member + accessor to `LspProtocol` |
| `src/compiler/lsp/protocol.cc` | Implement `emit_range_count` and `emit_range` |
| `src/compiler/lsp/lsp.h` | Add selection-range state, `set_selection_range_request`, `emit_selection_ranges` |
| `src/compiler/compiler.cc` | Add `Kind::selection_range`, command dispatch, `lsp_selection_range()`, hook in `Pipeline::run()` |
| `src/CMakeLists.txt` | Add new source files |
| `tools/lsp/server/compiler.toit` | Add `selection-range` method |
| `tools/lsp/server/server.toit` | Add handler + `build-selection-range` helper |
| `tools/lsp/server/protocol/server_capabilities.toit` | Add `--selection-range-provider` |
| `tools/lsp/server/client.toit` | Add `send-selection-range-request` |
| `tests/lsp/CMakeLists.txt` | Add glob + test dispatch |

## Key Design Decisions

1. **AST-only, no resolution needed.** SelectionRange is purely syntactic. We hook into the pipeline after parsing but before resolution, which is both correct and significantly faster than a full compilation.

2. **No `LspSelectionHandler`.** The existing selection handler mechanism detects *what an identifier resolves to*. SelectionRange needs *all containing syntactic scopes* — a fundamentally different traversal.

3. **`ast::TraversingVisitor` subclass.** This is the canonical way to walk the AST in the codebase. Using the `NODES(V)` macro for overrides ensures completeness and future-proofing.

4. **Multiple positions per request.** The LSP spec allows sending multiple positions. We handle them all in a single compiler invocation to avoid redundant parsing.

5. **Both `full_range()` and `selection_range()`.** For nodes where these differ (e.g., a method's `selection_range` is the name, `full_range` includes the body), we include both to give fine-grained selection steps.

6. **Innermost-first emission.** The C++ side sorts by range length and emits smallest first. The Toit side folds from the end to construct the `parent` chain.

7. **Toit-side chain construction.** The nested `SelectionRange` objects are built in Toit using simple map construction — idiomatic and consistent with how other protocol responses are built.

## Implementation Order

1. **C++ protocol** (`protocol.h/.cc`) — the wire format
2. **C++ visitor** (`selection_range.h/.cc`) — the core algorithm
3. **C++ Lsp hook** (`lsp.h`, `compiler.cc`) — pipeline integration
4. **Toit compiler method** (`compiler.toit`) — protocol parsing
5. **Toit server handler** (`server.toit`, `server_capabilities.toit`) — LSP dispatch
6. **Toit client method** (`client.toit`) — test infrastructure
7. **Tests** (`CMakeLists.txt`, runner, test files) — validation

Each step builds on the previous and is independently testable at the protocol boundary.
