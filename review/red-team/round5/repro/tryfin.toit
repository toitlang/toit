// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The base of red-team round 5 (format 3, step 3: TRY as a flagged block
// call, the pending unwinding in the finally code's token slots;
// verified/spec/format/23-format3-try.md). battery-T.sh replaces the body
// of `victim` with assembled code; the other methods are the shapes the
// compiler emits, for `asm dump` and as targets of calls.

sink x:
  print x

// A try/finally whose finally code reads the reason and the value.
with-params:
  try:
    sink 1
  finally: | is-exception exception |
    sink is-exception

// A try/finally inside a block loop with a non-local return.
with-return -> int:
  [0].do:
    try:
      return 7
    finally:
      sink 2
  return 0

// A try/finally whose body throws.
with-throw:
  try:
    throw "x"
  finally:
    sink 3

// The method battery-T.sh replaces. It has the same try/finally as
// with-params, so its frame is large enough for the patched bodies.
victim:
  try:
    sink 4
  finally: | is-exception exception |
    sink is-exception
    sink exception

// The other method battery-T.sh replaces: its try block throws "x".
victim-throw:
  try:
    throw "x"
  finally: | is-exception exception |
    sink is-exception
    sink exception.value

// Without arguments only victim runs, with "t" only victim-throw (its
// exception caught and printed); the others are kept for their shapes.
main args:
  if args.is-empty:
    victim
    return
  if args[0] == "t":
    sink (catch: victim-throw)
    return
  e := catch: with-throw
  sink e
  sink with-return
  with-params
