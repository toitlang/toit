// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

log := []

simple:
  try:
    log.add "body"
  finally:
    log.add "finally"

nested:
  try:
    try:
      log.add "inner body"
    finally:
      log.add "inner finally"
  finally:
    log.add "outer finally"

with-return -> int:
  try:
    return 42
  finally:
    log.add "finally after return"

with-throw:
  try:
    throw "boom"
  finally:
    log.add "finally after throw"

finally-args:
  try:
    throw "argh"
  finally: | is-exception exception |
    log.add "is-exception=$is-exception value=$exception.value"
    return  // Stops the unwinding.

finally-normal-args:
  try:
    log.add "no exception"
  finally: | is-exception exception |
    log.add "is-exception=$is-exception exception=$exception"

loop-finally:
  for i := 0; i < 3; i++:
    try:
      if i == 1: continue
      log.add "loop $i"
    finally:
      log.add "loop finally $i"

main:
  simple
  nested
  print with-return
  catch: with-throw
  finally-args
  finally-normal-args
  loop-finally
  log.do: print it
