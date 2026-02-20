# Toit Language Server Protocol (LSP) Implementation Guide

## Overview
The Toit LSP is implemented using a multi-component architecture:

- **Client (Editor)**: VSCode extension or test runner.
- **LSP Server (Toit)**: `tools/lsp/server/server.toit`. Handles JSON-RPC communication, manages document state, and spawns the compiler backend.
- **Compiler Backend (C++)**: `src/compiler/`. The `toit.run` or `toitc` process that performs the actual analysis, parsing, and data extraction (e.g., Goto Definition, Hover).

This guide focuses on implementing features in the compiler backend and debugging communication issues.

## Workflow

### 1. Building and Running
The project uses `make` (which invokes ninja).

**Build everything:**
```bash
make
```
(Using `make -j` is recommended for speed, but `make` alone is safer when debugging race conditions or build system quirks).

### 2. Testing LSP Features
To test a specific LSP feature (like Hover), you typically use a custom test runner written in Toit that mimics an LSP client.

**Command:**
```bash
build/host/sdk/lib/toit/bin/toit.run \
  tests/lsp/hover-test-runner.toit \
  tests/lsp/hover-compiler-test.toit \
  build/host/sdk/lib/toit/bin/toit.run \
  tools/lsp/server/server.toit \
  build/host/sdk/lib/toit/bin/toit.run
```

**Arguments:**
- `hover-test-runner.toit`: The test runner script.
- `hover-compiler-test.toit`: The source file being analyzed (with test annotations).
- `toit.run`: The executable to run the server.
- `server.toit`: The server implementation source.
- `toit.run`: The compiler executable path (passed to server).

### 3. Debugging
Because the LSP server runs as a subprocess and communication is via stdin/stdout, standard logging (`printf`, `std::cout`) is often swallowed or interferes with the protocol.

**Recommended Debugging Method:** Write to a dedicated log file.

```cpp
{
  FILE *f = fopen("/tmp/compiler_debug.txt", "a");
  if (f) {
    fprintf(f, "DEBUG: Reached critical section %p\n", some_pointer);
    fclose(f);
  }
}
```
Monitor this file in a separate terminal: `tail -f /tmp/compiler_debug.txt`.

### 4. Advanced Debugging (Verbose Mode)
For deeper integration issues where file logging is insufficient or slow, you can enable verbose mode in the server.

1.  **Modify `tools/lsp/server/client.toit`:**
    Add `"--verbose"` to the server arguments:
    ```toit
    server-args := [lsp-server, "--verbose"]
    ```

2.  **Use `verbose:` in Server Code:**
    In `tools/lsp/server/compiler.toit` or other server files, use the `verbose` function (defined in `tools/lsp/server/verbose.toit`) to log to stderr.
    ```toit
    import .verbose
    // ...
    verbose: "My debug message: $some-value"
    ```

    The test runner (`hover-test-runner.toit`) captures stderr and will print these messages to the console during the test run.

## Code Structure & Key Components

### C++ Compiler (`src/compiler/`)
- `compiler.cc`: Entry point for compilation pipelines.
  - `Pipeline::run`: Orchestrates parsing and resolution.
- `LocationLanguageServerPipeline`: Base for LSP features dealing with cursor location (like Hover).
- `HoverPipeline`: Specific implementation for Hover.
- `lsp/lsp.h`: The `Lsp` class manages handlers (`CompletionHandler`, `HoverHandler`).
- `lsp/selection.h`: `LspSelectionHandler` base class. Defines interface for handling different node types (call_virtual, type, etc.).
- `lsp/hover.cc`: `HoverHandler` implementation. Generates the response.
- `resolver.cc`: The `Resolver` class.
  - `resolve`: Main resolution loop.
  - `resolve_fill_method`: Populates `ToitdocRegistry` for methods.
- `type_check.cc`: The `TypeChecker`.
  - `visit_CallVirtual`: Detects if a call target is an `LspSelectionDot` (the cursor position) and notifies the handler.

### Toit Server (`tools/lsp/server/`)
- `server.toit`: Main loop. Dispatches requests.
- `file_server.toit`: Handling file system requests from the compiler. **CRITICAL COMPONENT**.
- `client.toit`: Mock client implementation used by tests.

## Implementing a Feature (Example: Hover)
1. **Define Pipeline**: Create a subclass of `LocationLanguageServerPipeline` (e.g., `HoverPipeline`) in `compiler.cc`.
2. **Register Handler**: In `Lsp::setup_hover_handler` (`lsp.cc`), instantiate your handler.
3. **Implement Handler**: Create `HoverHandler` in `lsp/hover.h/cc`. Inherit from `LspSelectionHandler`.
4. **Connect Trigger**: In `TypeChecker` or `Resolver`, identify the AST/IR node corresponding to the user's cursor.
   - The parser creates special `LspSelection` nodes for the token at the cursor.
   - `TypeChecker` sees this via `node->target()->is_LspSelectionDot()`.
   - Call `lsp_->selection_handler()->call_virtual(...)`.

## Critical Pitfalls & Lessons Learned

### 1. SDK Path Resolution (`sdk_lib_dir`)
**Issue:** The compiler failed to load `core.toit` when running in LSP mode, causing silent failures or crashes.
**Cause:** The `FilesystemLsp` relies on the client (the test runner/server) to provide the SDK path. The test environment (`toit.run` in build artifacts) has a nested structure: `build/host/sdk/lib/toit/bin/toit.run`.
**Fix:** `tools/lsp/server/file_server.toit` calculated the path assuming a standard layout (`bin/toit`). It needed to be updated to detect the deep build artifact structure and go up sufficient levels.
**Symptom:** `Filesystem::library_root` returns a malformed path (e.g., duplicated `lib/toit/lib`) or `Pipeline::_load_file` fails for `core.toit`.

### 2. Object Lifetimes (`ToitdocRegistry`)
**Issue:** `emit_hover` reported "No valid toitdoc" even though documentation existed.
**Cause:** The `ToitdocRegistry` is populated within the `Resolver`. However, the `Resolver` is destroyed after the resolution phase completes. The `HoverHandler` (which persists) was holding a reference to an empty or destroyed registry.
**Fix:** Explicitly **COPY** the `ToitdocRegistry` from the `Resolver` to the `LspSelectionHandler` before the `Resolver` is destroyed (in `Resolver::resolve`). Ensure `LspSelectionHandler` manages the memory of this copy (e.g., `owns_toitdocs_` flag).

### 3. File Logging
**Tip:** Always rely on file-based logging for the compiler process in LSP tests. Stdout/Stderr capture in test runners can be tricky or buffered.

### 4. Node Types (`ir::Reference`)
**Issue:** `HoverHandler` or other handlers fail to match the expected node type (e.g., `is_Method()`), resulting in empty responses or errors.
**Cause:** The compiler's IR often wraps resolved nodes in `ir::Reference` nodes (like `ReferenceMethod`, `ReferenceClass`).
**Fix:** Always check if a node is a `Reference` and unwrap it using `reference->target()` before performing type checks or casting.
```cpp
if (auto reference = node->as_Reference()) {
  node = reference->target();
}
// Now it's safe to check node->is_Method()
```

### 5. LSP Test Integration (`CMakeLists.txt`)
**Issue:** Hover tests (`*hover-test.toit`) were not being executed correctly; they parsed but skipped hover assertions, silently passing.
**Cause:** The test infrastructure relies on `CMakeLists.txt` mapping glob patterns (like `*definition-test.toit`) to their specific Toit runner scripts `goto-definition-test-runner.toit`. Because `*hover-test.toit` was initially unmapped, it fell back to a generic syntax check without firing the LSP mock client.
**Fix:** Explicitly map `*hover-test.toit` files to `hover-test-runner.toit` within `tests/lsp/CMakeLists.txt` using the `add_test` CMake directive.

### 6. Test Runner Argument Order
**Issue:** Directly invoking a test runner (e.g. `toit run tests/lsp/hover-test-runner.toit`) failed with `OUT_OF_BOUNDS` or `ILLEGAL_UTF_8` errors.
**Cause:** Target classes like `LocationCompilerTestRunner` enforce a strict arguments structure: `[test_file_path, compiler_executable, lsp_server_script, mock_compiler]`. Misordering strings causes the framework to treat binary paths as source tests.
**Fix:** Validate the exact invocation from `CTestTestfile.cmake`. Running tests via `ctest -R <test-name>` or `make test` ensures correct formatting rather than manually assembling the CLI parameters.

### 7. Exact Toitdoc Expectations (`/*^ ... */`)
**Issue:** Formatted hover tests failed assertions reporting `Expected <...>, but was <...>`.
**Cause:** The mock test runner does a strict verbatim text comparison against comment blocks written as `/*^ ... */` below the cursor position. Missing whitespaces, uncopied newlines, or omitting deprecation warnings included in the live `toitdoc` triggers a failure.
**Fix:** Manually capture the actual returned hover output (e.g., via `> result.txt 2>&1`) and perfectly paste the entire hover blob into the validation comment block.

### 8. Virtual Method Type Binding (`type.is_any()`)
**Issue:** Hovering over virtual method calls like `wait` returned `null` or wrong documentation inside complex modules, even when working in isolated unit tests.
**Cause:** `HoverHandler::call_virtual` initially searched for a matching method selector inside the unprioritized `classes` fallback list (containing all compilation classes). It matched an internal, undocumented class's method before ever reaching the true inferred target (e.g. `pipe.Process`).
**Fix:** Explicitly branch on `type.is_class()`. Start by traversing specifically from `type.klass()`, through its mixins and `super()`, only falling back to a global `classes` iteration if `type.is_any()`.

### 9. Reference Unwrapping in FindReferences
**Issue:** `textDocument/rename` returned `null` — zero references found even though the symbol clearly had usages.
**Cause:** `FindReferencesHandler::call_static` stored `target_` as the raw `ir::Node*` from the resolver callback (e.g., an `ir::ReferenceGlobal*`). The `FindReferencesVisitor` then compared `node->target() == target_`, but `node->target()` returns the **unwrapped** definition (e.g., `ir::Global*`). Pointer identity never matched.
**Fix:** Always unwrap Reference nodes via a `unwrap_reference()` helper before storing `target_` in the handler. This applies to **all** capture points: `call_static`, `class_interface_or_mixin`, `type`, `show`, `expord`. This is a specific instance of §4 above.
```cpp
static ir::Node* unwrap_reference(ir::Node* node) {
  if (node == null) return null;
  if (node->is_ReferenceMethod()) return node->as_ReferenceMethod()->target();
  if (node->is_ReferenceLocal()) return node->as_ReferenceLocal()->target();
  if (node->is_ReferenceGlobal()) return node->as_ReferenceGlobal()->target();
  if (node->is_ReferenceClass()) return node->as_ReferenceClass()->target();
  return node;
}
```
**Note:** `ir::Global` extends `ir::Method`, so `is_Method()` already covers globals.

### 10. `encode-map_` Strips Null Values
**Issue:** `renameProvider` was not recognized by LSP clients (lsp4ij, VSCode) despite being set.
**Cause:** `rpc.toit`'s `encode-map_` drops map entries with `null` values. `RenameOptions` with no arguments creates `{"prepareProvider": null}`, which serializes to an empty object `{}`. While technically valid, clients don't recognize `"renameProvider": {}`.
**Fix:** Use `--rename-provider= true` (a boolean) instead of `--rename-provider= RenameOptions`. This matches `--definition-provider= true` and `--hover-provider= true`.

### 11. Definition-Site Cursor Not Triggering Handler Callbacks
**Issue:** `textDocument/rename` returned null when the cursor was on a **definition** (e.g., `foo x:` or `my-global := 42`), but worked fine on a **reference** (usage) of the same symbol.
**Cause:** The LSP selection mechanism inserts a dot-marker (`LspSelectionDot`) at the cursor, which the resolver handles as a synthetic call expression. At definition sites, there is no call to resolve, so no handler callback is ever invoked and `target_` stays null.
**Fix:** Added `find_definition_at_cursor` fallback in `FindReferencesPipeline::post_resolve`. When the handler's target is null, it scans the program's top-level definitions (globals, methods, classes, and class fields) and finds the one whose name `range()` contains the cursor position. Uses `SourceManager::compute_location` to convert opaque `Source::Position` values to comparable line/column pairs.
**Limitation:** This fallback only covers program-level definitions. Local variables inside method bodies are not in the program-level lists, so renaming a local requires placing the cursor on a usage.

## Future Improvements
- **Toitdoc Markdown**: The `HoverHandler` implementation for `ToitdocMarkdownVisitor` can be extended to support more advanced markdown features.
- [x] **Signature Display**: Fallback to method/class signature is implemented.
