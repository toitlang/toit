# LSP Rename Implementation — Architecture & Design

This document describes the rename and prepareRename implementation for the
Toit LSP server.  Every design decision is justified in context so that the
implementation can be defended in code review.

---

## Overview

The rename feature allows users to rename symbols (functions, classes, fields,
parameters, locals, globals) and have all references updated across the entire
project.  It is split into two LSP requests:

| Request | Purpose |
|---|---|
| `textDocument/prepareRename` | Validates whether rename is possible at the cursor and returns the extent of the symbol to replace. |
| `textDocument/rename` | Computes all locations that must be updated and returns a `WorkspaceEdit`. |

Both requests share the same C++ infrastructure (handler, filter, visitor) and
differ only in their pipeline orchestration.

---

## File Layout

### C++ (compiler side)

| File | Purpose |
|---|---|
| `src/compiler/lsp/rename.h` | Declares `FindReferencesHandler`, `VirtualCallFilter`, `FindReferencesVisitor` and helper functions (`unwrap_reference`, `target_name`, `target_range`, `is_sdk_target`). |
| `src/compiler/lsp/rename.cc` | Implements the handler callbacks, the filter's hierarchy computation and ambiguity detection, and the visitor's expression-level reference scanning. |
| `src/compiler/compiler.cc` | Contains `FindReferencesPipeline` and `PrepareRenamePipeline` — the compiler pipelines that invoke the handler, build the filter, run program-level scanning (hierarchy, type annotations, field-storing params, show/export clauses), and delegate to the visitor. |
| `src/compiler/resolver_method.cc` | Stores `ir_to_ast_map_` entries during method resolution to preserve AST source ranges needed by the visitor (setter CallVirtual → AST name, Typecheck → AST type, Call with named args → AST Call). |

### Toit (server side)

| File | Purpose |
|---|---|
| `tools/lsp/server/server.toit` | `rename` method: walks reverse-dependency graph to find compilation entry points, invokes the compiler's find-references protocol per entry point, deduplicates results, and builds the `WorkspaceEdit`.  `prepare-rename` method: thin wrapper around the compiler's prepare-rename protocol. |
| `tools/lsp/server/compiler.toit` | `find-references` / `prepare-rename` methods: send the 5-line LSP protocol (`REFERENCES\n<path>\n<line>\n<col>\n<entry-path>`) to the compiler process and parse the response. |

### Tests

| File | Scenario |
|---|---|
| `basic-rename-test.toit` | Top-level function rename |
| `locals-rename-test.toit` | Local variable rename |
| `param-rename-test.toit` | Parameter rename (declaration + body usage) |
| `named-arg-rename-test.toit` | Named parameter rename including call-site `--param` tokens |
| `named-ctor-rename-test.toit` | Named constructor rename |
| `class-rename-test.toit` | Class rename (constructors, types, hierarchy) |
| `class-extended-rename-test.toit` | Class rename across extends/implements/with |
| `type-annot-rename-test.toit` | Class rename in type annotations |
| `field-rename-test.toit` | Field rename (getter/setter virtual calls) |
| `field-storing-rename-test.toit` | Field-storing parameter rename |
| `virtual-method-rename-test.toit` | Virtual method rename (hierarchy + call sites) |
| `ambiguous-method-rename-test.toit` | Ambiguous method name (package filtering) |
| `abstract-method-rename-test.toit` | Abstract method rename |
| `block-param-rename-test.toit` | Block parameter rename (`[param]` syntax) |
| `constant-rename-test.toit` | Constant/global rename |
| `static-const-rename-test.toit` | Static constant rename |
| `static-method-rename-test.toit` | Static method rename |
| `global-rename-test.toit` | Global variable rename |
| `show-clause-rename-test.toit` | Rename updates `show` clauses |
| `operator-rename-test.toit` | Operator rename rejection |
| `sdk-field-rename-test.toit` | SDK symbol rejection |
| `cross-file-*-rename-test.toit` | Cross-file rename for functions, classes, fields, virtual methods |
| `*-prepare-rename-test.toit` | 25 prepareRename tests covering the same scenarios |

Two test runners (`rename-test-runner.toit`, `prepare-rename-test-runner.toit`)
parse marker annotations `/* ^ N */` from test files and drive the LSP protocol.

---

## Architecture

### Phase 1: Target Identification (FindReferencesHandler)

When the compiler resolves expressions and encounters the LSP cursor position,
it invokes callbacks on the `LspSelectionHandler`.  `FindReferencesHandler`
implements these callbacks to identify the rename target:

```
User cursor → resolver callbacks → FindReferencesHandler → target_ + cursor_range_
```

**Callbacks implemented:**

| Callback | Fires when | Target resolution |
|---|---|---|
| `call_static` | Cursor on a statically-resolved identifier | Unwraps Reference to get the Method/Class/Global |
| `call_class` | Cursor on `Class.member` | Looks up the static member; delegates to `call_static` |
| `call_virtual` | Cursor on a virtual call selector | Walks class hierarchy to find the matching Method |
| `call_static_named` | Cursor on `--param_name` at a call site | Resolves to the ir::Parameter of the target method |
| `call_prefixed` | Cursor on `prefix.symbol` | Delegates to `call_static` |
| `class_interface_or_mixin` | Cursor on a class/interface/mixin name | Unwraps to the Class node |
| `type` | Cursor on a type annotation | Unwraps the resolved entry |
| `field_storing_parameter` | Cursor on a field-storing `--param` | Resolves to the ir::Field |
| `show` / `expord` | Cursor on a show/export clause | Unwraps the resolved entry |

**Design decisions in target identification:**

1. **Unnamed constructor → class redirect:**  When the cursor is on an
   invocation like `MyObj 42` that resolves to an unnamed constructor, the
   target is redirected to the *class*.  The user intends to rename the class
   name (which appears at the call site), not the synthetic constructor.  Named
   constructors (e.g., `constructor.deserialize`) are NOT redirected — the user
   intends to rename the constructor's own name.

2. **Cross-module `call_static_named` fallback:**  When the cursor is on
   `--param` at a call site, the target method's parameter list may not yet be
   populated (cross-module methods resolve lazily).  The handler falls back to
   the method's `resolution_shape().names()` list and creates a temporary
   `ir::Local` node to carry the cursor range for `prepareRename`.

3. **`cursor_range_` vs definition range:**  The handler stores the *cursor
   site* range (the identifier the user clicked on) separately from the
   target's definition range.  This is because `prepareRename` must return the
   range at the cursor, not at the definition.  For Dot nodes like `Foo.bar`,
   the name identifier's range is used (not the full Dot range that would
   include the `.` prefix).

### Phase 2: Virtual Call Filtering (VirtualCallFilter)

Virtual calls in the IR carry only a selector name and a call shape — no
resolved method target.  Without full type-flow analysis, we cannot know which
concrete method a virtual call dispatches to.  The `VirtualCallFilter` uses a
multi-layer strategy to decide whether a virtual call should be included:

```
VirtualCallFilter::build(target_method, program, source_manager)
  → compute_participating_classes()     // class hierarchy
  → detect_ambiguity()                  // name/shape uniqueness

VirtualCallFilter::should_include(CallVirtual* node)
  → selector match?
  → shape match? (getter or setter)
  → unambiguous? → include all
  → ambiguous? → same file? same package? → include/skip
```

**Five layers of filtering:**

1. **Operator exclusion:**  Operators (`+`, `[]`, etc.) cannot be meaningfully
   renamed — they are language-defined tokens.  The filter is inactive for
   operators.

2. **Class hierarchy computation** (3-phase fixed-point):
   - Phase 1: Walk up from the holder through superclasses.
   - Phase 2: Add connected interfaces and mixins.
   - Phase 3: Fixed-point iteration to add all descendants.
   This produces the set of all classes that participate in the method's virtual
   dispatch.

3. **Ambiguity detection:**  Scan all classes outside the participating set.
   If any class defines a method with the same name and compatible shape, the
   name is "ambiguous."  This means a virtual call with that selector could
   dispatch to an unrelated hierarchy.

4. **SDK exclusion:**  SDK methods cannot be renamed (their source files are
   not user-editable).  The filter is inactive for SDK targets.

5. **Package-based proximity filtering** (ambiguous names only):
   - Same source file as the target → include (highest confidence).
   - Same package as the target → include (likely same hierarchy).
   - Different package → skip (risk of false positive).

**Why not use type-flow analysis?**  The Toit compiler does not perform
type-flow analysis during the LSP resolution phase.  The rename feature runs
after the resolver (or after the type checker for some pipeline paths), but
before any whole-program analysis.  The multi-layer heuristic provides a
practical approximation that is correct for the vast majority of cases:
unambiguous method names (the common case) match exactly, and ambiguous names
use package proximity as a sound conservative filter.

### Phase 3: Program-Level Reference Scanning (emit_all_references)

Before delegating to the visitor for expression-level traversal,
`emit_all_references` handles several categories of references that require
program-level iteration rather than expression-level visiting:

1. **Definition emission:**  Emits the target's own definition location with
   prefix trimming.

2. **Override/implementation definitions:**  When renaming a virtual method or
   field, all definitions in participating classes with matching name and shape
   must be renamed together.  FieldStub overrides emit the underlying field's
   range.

3. **Class hierarchy references:**  For class targets, scans `extends`,
   `implements`, and `with` clauses across all classes.

4. **Type annotation references:**  Scans parameter types, return types, and
   field types across all methods and classes.

5. **Field-storing parameter references:**  Scans constructors/factories for
   field-storing parameters (`--.field`) that share the field's name.

6. **Show/export clause references:**  Scans the resolver's show/export
   registry for clauses referencing the renamed symbol.

These are handled at the program level (not in the visitor) because they
require iterating over structural metadata (class hierarchies, type
annotations, parameter lists) rather than expression trees.

### Phase 4: Expression-Level Reference Scanning (FindReferencesVisitor)

The visitor traverses all IR expression trees to find references:

| Visitor method | Handles |
|---|---|
| `visit_Reference` | Static references (ReferenceLocal, ReferenceGlobal, ReferenceMethod). Also matches unnamed constructor/factory references when renaming a class. |
| `visit_CallVirtual` | Virtual call sites matching the VirtualCallFilter. For setter calls, uses `ir_to_ast_map` to get the AST name node (since CallVirtual::range() covers `=`, not the field name). |
| `visit_CallStatic` | Named argument call sites. When the target is a Parameter, checks if the call's target method owns the parameter and emits the named argument's source range. Handles both static calls and constructor calls (since `CallConstructor` dispatches through `visit_CallStatic` by default in `TraversingVisitor`). |
| `visit_Typecheck` | IS/AS/LOCAL_AS type checks for class targets. Uses `ir_to_ast_map` for the AST type node. |

**Range trimming:**  The `emit_range` method adjusts emitted ranges to cover
exactly the identifier name.  Source ranges in the IR often include prefix
syntax that is not part of the renamable name:

| Prefix | Example | Range covers | After trimming |
|---|---|---|---|
| `--` | `--param` | `--param` | `param` |
| `[` | `[block_arg]` | `[block_arg]` | `block_arg` |
| `.` | `.member` | `.member` | `member` |
| `constructor.` | `constructor.name` | `constructor.name` | `name` |

Trimming uses `target_name_len_` to compute `start_col = end_col - name_len`.
This is the same technique used for both definition and reference ranges.

**Definition deduplication:**  The visitor filters out emissions whose range
exactly matches the definition site.  This prevents double-counting when the
compiler generates a `ReferenceLocal` at the parameter definition position
(e.g., for typed parameter checks that create implicit `Typecheck` nodes).

---

## Named Argument Rename at Call Sites

### Problem

In Toit, named parameters like `--param_name` can be referenced at call sites:

```toit
foo --param_name=42
```

When renaming `param_name`, the `--param_name` token at each call site must
also be updated.  The challenge is that the resolver *discards* `ast::NamedArgument`
nodes during call resolution — it extracts the `Symbol` name and resolved
expression, then builds positional arguments in `CallBuilder`.  The resulting
`ir::CallStatic` carries a `CallShape` with `names()` (a list of Symbols), but
no source ranges for the named argument tokens.

### Solution

**Resolver (resolver_method.cc):**  During `_visit_potential_call`, when
processing arguments, a `has_named_arguments` flag is set if any argument is a
`NamedArgument`.  After the call dispatch (which pushes the IR call onto the
stack), if named arguments were present and the AST node is a `Call`, the
mapping `ir_call → ast_call` is stored in `ir_to_ast_map_`.

```cpp
if (ir_to_ast_map_ != null && has_named_arguments && !stack_.empty() &&
    potential_call->is_Call()) {
  (*ir_to_ast_map_)[stack_.back()] = potential_call;
}
```

Only `ast::Call` nodes are mapped (not `Index`/`IndexSlice`), since only
user-written calls with named arguments should participate in rename.
`IndexSlice` creates synthetic `NamedArgument` nodes internally (for `from`/`to`
parameters) that are not user-visible.

**Visitor (rename.cc):**  `visit_CallStatic` checks whether the rename target
is a Parameter and whether the call's target method owns that parameter.  If
so, it calls `emit_named_argument_reference`, which looks up the AST call via
`ir_to_ast_map_`, walks its arguments to find the `NamedArgument` whose name
matches, and emits its source range.

This approach is consistent with the existing `ir_to_ast_map` pattern used for:
- Setter `CallVirtual` → AST name node (for field access ranges)
- `Typecheck` → AST type node (for class name ranges in is/as checks)
- `ir::Parameter` → `ast::Parameter` (for typed parameter checks)
- `ir::Method` → `ast::Method` (for named constructor definition ranges)

### Why not store ranges in CallShape?

An alternative would be to add source ranges to `CallShape::names()`.  This
was rejected because:

1. `CallShape` is a core IR data structure used throughout the compiler.
   Adding LSP-only range data would pollute the IR with concerns that are
   irrelevant to compilation, type checking, and code generation.

2. `CallShape::names()` is alphabetically sorted for efficient lookup, which
   would complicate maintaining source-order ranges alongside sorted names.

3. The `ir_to_ast_map` approach is already established for analogous problems
   (setter ranges, type check ranges) and keeps LSP concerns isolated to the
   LSP code paths.

### Scope: Static vs Virtual Calls

Named argument call-site rename is currently implemented for:
- **Static function calls** (`CallStatic`)
- **Constructor calls** (`CallConstructor`, which dispatches through
  `visit_CallStatic` via `TraversingVisitor`)

It is **not yet implemented** for virtual calls (`CallVirtual`), because:
- The `VirtualCallFilter` is built from `ir::Method*` targets, but when the
  rename target is a `Parameter`, there is no method to build the filter from.
- Virtual method parameter rename (including cascading to override parameter
  declarations) is a separate, larger feature.
- The resolver's `call_static_named` callback does not fire for dot-call
  virtual invocations (only for statically-resolved calls and super calls).

This limitation is well-scoped: named parameters on virtual methods are less
common, and the most frequent use case (static functions, constructors,
factories) is fully supported.

---

## Cross-File Rename

### Problem

Toit projects consist of multiple files connected by `import` statements.
When renaming a symbol, all files that reference it must be updated.  However,
the compiler processes one entry point at a time — it compiles the entry file
and all its transitive imports.

### Solution

The Toit server implements a reverse-dependency walk:

1. **Find entry points:**  Starting from the file containing the cursor,
   walk the reverse-dependency graph upward to find all *root* files — files
   that are not imported by any other file in the project closure.  These are
   the compilation entry points.

2. **Compile per entry point:**  For each entry point, invoke the compiler's
   `find-references` protocol.  Each compilation covers the entry point and
   all its transitive imports, producing a set of reference locations.

3. **Deduplicate:**  References from different entry points may overlap
   (two entry points may import the same file).  The server deduplicates
   by `URI:line:column` key before building the `WorkspaceEdit`.

This approach ensures complete coverage: every file that can "see" the renamed
symbol is compiled through at least one entry point.

---

## Safety Guards

### SDK Rejection

SDK symbols (from the `sdk` package) cannot be renamed because their source
files are not user-editable.  The check is applied:
- In `emit_all_references` (exits immediately for SDK targets)
- In `VirtualCallFilter::build` (disables the filter for SDK methods)
- In `is_sdk_target` (checks the source's `package_id`)

Locals and parameters are exempted from this check: even if their type comes
from the SDK, the parameter itself lives in user code.

### Operator Rejection

Operators (`+`, `-`, `[]`, `[]=`, etc.) cannot be meaningfully renamed —
they are fixed-syntax tokens.  Checked in `VirtualCallFilter::build` via
`is_operator_name`.

### PrepareRename Validation

`prepareRename` returns `null` (indicating rename is not possible) when:
- The cursor is not on a renamable identifier
- The target is an SDK symbol
- The target is an operator

This gives immediate feedback to the user before they type a new name.

---

## ir_to_ast_map Usage Pattern

The `ir_to_ast_map` is a resolver-maintained map from IR nodes to their
originating AST nodes.  It is used when the IR node's source range does not
accurately represent the text that needs to be renamed.

| Mapping | Why | Used by |
|---|---|---|
| `ir::Parameter → ast::Parameter` | Parameter type annotation range | Class type annotation scanning |
| `ir::Method → ast::Method` | Named constructor definition range (IR range covers "constructor", AST Dot name has the actual name) | `emit_all_references` definition emission |
| `ir::Class → ast::Class` | Extends/implements/with clause ranges | Class hierarchy scanning |
| `ir::Field → ast::Field` | Field type annotation range | Class type annotation scanning |
| setter `ir::CallVirtual → ast::Node` | Setter call range (IR covers `=`, AST name node has the field name) | `visit_CallVirtual` |
| `ir::Typecheck → ast::Node` | Type name range in is/as checks | `visit_Typecheck` |
| `ir::Call → ast::Call` | Named argument source ranges (IR discards NamedArgument AST nodes) | `visit_CallStatic` → `emit_named_argument_reference` |

This pattern is the standard way to bridge between the IR's simplified range
information and the AST's detailed source ranges.  It avoids polluting IR
nodes with LSP-only data.

---

## Known Limitations

1. **Named parameter rename on virtual methods:**  Call-site `--param_name`
   tokens are not updated for virtual calls (e.g., `obj.method --param=1`).
   This requires finding the parameter's owning method, building a
   VirtualCallFilter from it, and handling parameter rename cascading across
   method overrides.

2. **Toitdoc references:**  `$symbol` references in documentation comments
   are not updated during rename.

3. **String literals:**  If a symbol name appears in a string literal, it
   is not updated (this is standard LSP behavior — strings are not semantic
   references).

4. **Ambiguous virtual methods in different packages:**  When two unrelated
   class hierarchies define methods with the same name and shape, virtual
   call sites in *different* packages from both hierarchies are conservatively
   excluded.  This prevents false positives at the cost of potential false
   negatives for cross-package call sites.
