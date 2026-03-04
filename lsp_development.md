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
The correct way to run LSP tests is using `ctest` with a regular expression matching the feature you are testing. There is no need to manually invoke custom test runners.

**Command:**
```bash
ctest --test-dir build/host --verbose -C slow -R 'tests/lsp/.*hover'
```
Adjust the regular expression `-R 'tests/lsp/.*hover'` to match the specific tests you want to execute (e.g., `.*completion`, `.*rename`).

### 3. Debugging
Because the LSP server runs as a subprocess and communicates via stdin/stdout, standard `printf` to `stdout` interferes with the protocol.

**Recommended Debugging Method:**
For simple debugging, write to `stderr` (e.g., `fprintf(stderr, ...)`, `std::cerr`). The standard error stream is not removed or swallowed by the LSP communication, so messages will appear in the test output.

Writing to a dedicated log file is also a viable and easy alternative, especially during automated/AI-assisted debugging:

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
The server has a verbose mode. This is primarily interesting if you consider leaving the debugging code in the repository. For simple, temporary debugging, `printf` to `stderr` or a file is better.

If you want to use the verbose logging in the server code (Toit):

1.  **Enable Verbose Mode:** Ensure the server is started with `--verbose`.
2.  **Use `verbose:` in Server Code:**
    Use the `verbose` function (defined in `tools/lsp/server/verbose.toit`) to log to stderr conditionally based on the verbose flag.
    ```toit
    import .verbose
    // ...
    verbose: "My debug message: $some-value"
    ```

## Implementing a Feature (Example: Hover)
1. **Define Pipeline**: Create a subclass of `LocationLanguageServerPipeline` (e.g., `HoverPipeline`) in `compiler.cc`.
2. **Register Handler**: In `Lsp::setup_hover_handler` (`lsp.cc`), instantiate your handler.
3. **Implement Handler**: Create `HoverHandler` in `lsp/hover.h/cc`. Inherit from `LspSelectionHandler`.
4. **Connect Trigger**: In `TypeChecker` or `Resolver`, identify the AST/IR node corresponding to the user's cursor.
   - The parser creates special `LspSelection` nodes for the token at the cursor.
   - `TypeChecker` sees this via `node->target()->is_LspSelectionDot()`.
   - Call `lsp_->selection_handler()->call_virtual(...)`.
