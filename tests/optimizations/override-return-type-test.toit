// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .utils
import ...tools.snapshot show *
import expect show *

main args:
  snap := run args --entry-path="///untitled" {
    "///untitled": """
    class Foo:
      foo -> string: return "Foo"

    class Bar:
      foo -> string: return "Bar"

    class Holder:
      get -> Foo: return Foo

    class SameHolder extends Holder:
      get -> Foo: return Foo

    class LyingHolder:
      get -> Foo: return Foo

    class LyingSub extends LyingHolder:
      get: return Bar

    trusted holder/Holder:
      x := holder.get
      return x.foo

    untrusted holder/LyingHolder:
      x := holder.get
      return x.foo

    main:
      trusted Holder
      trusted SameHolder
      untrusted LyingHolder
      untrusted LyingSub
    """
  }

  program := snap.decode
  methods := extract-methods program ["trusted", "untrusted"]
  // Overrides that keep the return type: `x.foo` is devirtualized.
  expect (calls-foo-statically program methods["trusted"])
  // `LyingSub.get` returns any type, so `x` might not be a `Foo`.
  expect-not (calls-foo-statically program methods["untrusted"])

calls-foo-statically program/Program method/ToitMethod -> bool:
  result := false
  method.do-bytecodes: |bytecode bci|
    if bytecode.name == "INVOKE_STATIC":
      target := target-of-invoke-static program method bci
      if target.name == "foo": result = true
  return result
