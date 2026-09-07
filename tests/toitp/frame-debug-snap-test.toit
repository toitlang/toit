// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ...tools.snapshot

main args:
  snapshot := SnapshotBundle.from-file args[0]
  program := snapshot.decode
  inspect-info/MethodInfo? := null
  program.do --method-infos: | method/MethodInfo |
    if method.name == "inspect": inspect-info = method
  expect-not-null inspect-info
  frame-debug := program.frame-debug-info-for inspect-info.id
  expect-equals 3 frame-debug.parameters.size
  expect-equals "this" frame-debug.parameters[0].name
  expect-equals "receiver" frame-debug.parameters[0].kind
  expect-equals "first" frame-debug.parameters[1].name
  expect-equals "second" frame-debug.parameters[2].name
  local/LocalDebugInfo? := null
  frame-debug.locals.do: | candidate/LocalDebugInfo |
    if candidate.name == "local": local = candidate
  expect-not-null local
  expect-equals "local" local.name
  expect-equals 0 local.stack-height
  expect (local.start-bci < local.end-bci)
  synthetic-temporary/LocalDebugInfo? := null
  frame-debug.locals.do: | candidate/LocalDebugInfo |
    if candidate.name == "<tmp>": synthetic-temporary = candidate
  expect-not-null synthetic-temporary
  expect-equals (Position 0 0) synthetic-temporary.position
