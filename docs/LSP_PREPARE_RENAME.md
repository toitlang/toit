# LSP prepareRename — Test Coverage & Bug Fixes

## Overview

This document summarizes the prepareRename test coverage added and the bugs discovered and fixed in the Toit compiler's LSP prepareRename implementation.

## Test Files Created (19 tests, all passing)

| Test File | What It Tests |
|-----------|--------------|
| `param-decl-prepare-rename-test.toit` | Parameter at declaration site |
| `param-usage-prepare-rename-test.toit` | Parameter at usage site |
| `type-annot-prepare-rename-test.toit` | Type annotation (e.g. `foo/MyClass`) |
| `field-storing-prepare-rename-test.toit` | Field-storing parameter (`.field`) |
| `named-ctor-prepare-rename-test.toit` | Named constructor (`constructor.bar`) |
| `extends-prepare-rename-test.toit` | Class name in `extends` clause |
| `member-access-prepare-rename-test.toit` | Virtual method call (`obj.method`) |
| `global-var-prepare-rename-test.toit` | Top-level global variable |
| `named-param-prepare-rename-test.toit` | Named parameter (`--name`) |
| `static-method-prepare-rename-test.toit` | Static method |
| `mixin-with-prepare-rename-test.toit` | Mixin in `with` clause |
| `constant-prepare-rename-test.toit` | Top-level constant |
| `return-null-prepare-rename-test.toit` | Non-renameable position (expects null) |
| `abstract-method-prepare-rename-test.toit` | Abstract method declaration |
| `static-const-prepare-rename-test.toit` | Static class constant |
| `block-param-prepare-rename-test.toit` | Block parameter |
| `class-in-static-call-prepare-rename-test.toit` | Class name in static call (`Foo.bar`) |
| `instantiation-prepare-rename-test.toit` | Class name at constructor call (`MyObj`) |
| `return-type-prepare-rename-test.toit` | Return type annotation |

## Bugs Found & Fixed

### 1. Segfault: Dangling Reference in `DefinitionFinder` (7 tests crashed)

**File:** `src/compiler/compiler.cc`

**Root cause:** `DefinitionFinder` stored a `const std::function<bool(Source::Range)>&` member. When constructed with a lambda, the lambda was implicitly converted to a temporary `std::function`, and a reference to that temporary was stored. After the constructor returned, the temporary was destroyed, leaving a dangling reference.

**Fix:** Changed the member to store by value (`std::function<bool(Source::Range)>`) and accept by value with `std::move` in the constructor.

**Tests affected:** param-usage, type-annot, extends, member-access, mixin-with, class-in-static-call, instantiation

---

### 2. `find_definition_at_cursor` Incomplete Scope Search

**File:** `src/compiler/compiler.cc`

**Root cause:** `find_definition_at_cursor` only searched classes and fields. It did not search:
- Class methods (`klass->methods()`)
- Unnamed constructors (`klass->unnamed_constructors()`)
- Factories (`klass->factories()`)
- Statics (`klass->statics()->nodes()`)

**Fix:** Added iteration over all four additional scopes.

**Tests affected:** abstract-method, static-method (via statics)

---

### 3. `call_virtual` Not Implemented in `FindReferencesHandler`

**File:** `src/compiler/lsp/rename.h`

**Root cause:** `FindReferencesHandler::call_virtual` was an empty stub (`{}`). Virtual method calls (e.g. `obj.method`) never resolved to a target.

**Fix:** Implemented method resolution by selector matching — first tries type-based resolution walking the class hierarchy, then falls back to searching all classes.

**Tests affected:** member-access

---

### 4. Virtual Calls Resolved After `post_resolve` — Missing `post_type_check`

**File:** `src/compiler/compiler.cc`

**Root cause:** `call_virtual` is invoked from `type_check.cc`, not from the resolver. `PrepareRenamePipeline` only had a `post_resolve` override that would `exit(0)` when no target was found, preventing type-checking from ever running. Virtual call targets were never discoverable.

**Fix:** Added `post_type_check` override to `PrepareRenamePipeline`. Changed `post_resolve` to `return` (not exit) when target is null, allowing type-checking to proceed.

**Tests affected:** member-access

---

### 5. `call_static` Overwrites Target Set by `class_interface_or_mixin`

**File:** `src/compiler/lsp/rename.cc`

**Root cause:** For a static call like `Foo.bar`, `class_interface_or_mixin` correctly set the target to the `Foo` class. Then `call_class` delegated to `call_static`, which overwrote the target with the `bar` method.

**Fix:** Added `if (target_ != null) return;` guard at the top of `call_static`.

**Tests affected:** class-in-static-call

---

### 6. Constructor Call Returns "constructor" Instead of Class Name

**File:** `src/compiler/lsp/rename.cc`

**Root cause:** For `MyObj` (unnamed constructor call), the target resolved to the constructor method, whose name is literally `"constructor"`. The prepareRename response returned "constructor" as the placeholder instead of the class name.

**Fix:** After target resolution in `call_static`, detect if the target is a constructor or factory with a holder class, and resolve to the holder class instead.

**Tests affected:** instantiation

---

### 7. Named Constructor IR Range Points to Wrong Token

**File:** `src/compiler/resolver.cc`

**Root cause:** For `constructor.bar`, the IR method's position range was set to the entire `constructor.bar` selection range, which spanned the `constructor` keyword. When the cursor was on `bar`, it didn't match the method's range.

**Fix:** For named constructors/factories (where `method->name_or_dot()->is_Dot()`), use `method->name_or_dot()->as_Dot()->name()->selection_range()` to point specifically at the name portion (`bar`).

**Tests affected:** named-ctor

## Files Modified

| File | Changes |
|------|---------|
| `src/compiler/compiler.cc` | Fix dangling ref, expand `find_definition_at_cursor`, add `post_type_check` override, extract `emit_prepare_rename` helper |
| `src/compiler/lsp/rename.h` | Implement `call_virtual` method resolution |
| `src/compiler/lsp/rename.cc` | Add `call_static` guard, constructor→class resolution |
| `src/compiler/resolver.cc` | Fix named constructor range to point at name token |

## Regression Testing

All pre-existing LSP tests verified passing:
- goto-definition tests (basic, field, member, static, type, interface, mixin, extends, lambda, keyword, this-super, toitdoc)
- rename tests (basic-rename, locals-rename)
- prepareRename tests (basic-prepare-rename, locals-prepare-rename)
- hover tests (basic-hover)
- completion tests (basic-completion, assig-completion)
