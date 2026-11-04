// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

// Every name the VM knows, and the ones each platform supports.
ALL-NAMES ::= [
  "HUP", "INT", "QUIT", "KILL", "USR1", "USR2", "PIPE", "ALRM", "TERM", "CHLD",
  "CONT", "STOP", "TSTP", "TTIN", "TTOU", "WINCH", "BREAK", "INFO",
]
WINDOWS-NAMES ::= ["INT", "KILL", "TERM", "WINCH", "BREAK"]
POSIX-NAMES ::= ALL-NAMES.filter: it != "BREAK" and it != "INFO"
MACOS-NAMES ::= POSIX-NAMES + ["INFO"]
// Can only be raised.
UNCATCHABLE-NAMES ::= ["KILL", "STOP"]

// Platform signal numbers. Null for signals the platform doesn't have.
INT ::= signal-number_ "INT"
TERM ::= signal-number_ "TERM"
KILL ::= signal-number_ "KILL"
USR1 ::= signal-number_ "USR1"
PIPE ::= signal-number_ "PIPE"
CHLD ::= signal-number_ "CHLD"
// Not a signal number on any platform.
BOGUS ::= 1000

// Positional state bits.
BIT0 ::= 1 << 0
BIT1 ::= 1 << 1

// One group per process, like the signal library.
group_ ::= signal-init_

main:
  if system.platform == system.PLATFORM-FREERTOS: return
  test-numbers
  test-invalid
  test-watch
  test-watch-each
  test-multiple-watchers
  if system.platform != system.PLATFORM-WINDOWS:
    test-ignore
    test-ignore-chld
    test-pipe

supported-names -> List:
  if system.platform == system.PLATFORM-WINDOWS: return WINDOWS-NAMES
  if system.platform == system.PLATFORM-MACOS: return MACOS-NAMES
  return POSIX-NAMES

test-numbers:
  supported := supported-names
  ALL-NAMES.do: | name |
    expect-equals (supported.contains name) ((signal-number_ name) != null)
  expect-null (signal-number_ "BOGUS")
  expect-null (signal-number_ "")

  // The numbers that are the same on every platform that has them, so code
  // may use them directly.
  expect-equals 2 INT
  expect-equals 15 TERM
  expect-equals 9 KILL
  if system.platform != system.PLATFORM-WINDOWS:
    expect-equals 1 (signal-number_ "HUP")

test-invalid:
  expect-equals "INVALID_ARGUMENT" (catch: signal-watch_ group_ (Array_.ensure []))
  expect-equals "INVALID_ARGUMENT" (catch: signal-watch_ group_ (Array_.ensure [0]))
  expect-equals "INVALID_ARGUMENT" (catch: signal-watch_ group_ (Array_.ensure [-1]))
  expect-equals "INVALID_ARGUMENT" (catch: signal-watch_ group_ (Array_.ensure [BOGUS]))
  expect-equals "INVALID_ARGUMENT" (catch: signal-watch_ group_ (Array_.ensure [INT, BOGUS]))
  expect-equals "INVALID_ARGUMENT" (catch: signal-watch_ group_ (Array_.ensure (List 31 INT)))
  expect-equals "WRONG_OBJECT_TYPE" (catch: signal-watch_ group_ (Array_.ensure ["INT"]))
  expect-equals "WRONG_OBJECT_TYPE" (catch: signal-watch_ group_ (Array_.ensure [null]))
  expect-equals "INVALID_ARGUMENT" (catch: signal-reset_ 0)
  expect-equals "INVALID_ARGUMENT" (catch: signal-ignore_ BOGUS)
  expect-equals "INVALID_ARGUMENT" (catch: signal-raise_ BOGUS)
  UNCATCHABLE-NAMES.do: | name |
    number := signal-number_ name
    if number:
      expect-equals "INVALID_ARGUMENT" (catch: signal-watch_ group_ (Array_.ensure [number]))
      expect-equals "INVALID_ARGUMENT" (catch: signal-reset_ number)
      expect-equals "INVALID_ARGUMENT" (catch: signal-ignore_ number)

with-watch signals/List [block]:
  resource := signal-watch_ group_ (Array_.ensure signals)
  state := ResourceState_ group_ resource
  try:
    block.call state
  finally:
    state.dispose
    signal-unwatch_ resource group_

test-watch:
  with-watch [INT, TERM]: | state/ResourceState_ |
    signal-raise_ TERM
    expect-equals BIT1 (state.wait-for-state (BIT0 | BIT1))
    state.clear-state BIT1

    signal-raise_ INT
    expect-equals BIT0 (state.wait-for-state (BIT0 | BIT1))
    state.clear-state BIT0

    // Both pending at once.
    signal-raise_ INT
    signal-raise_ TERM
    while (state.wait-for-state (BIT0 | BIT1)) != (BIT0 | BIT1):
      sleep --ms=1
    state.clear

  // The bits follow the list order, and duplicates report on every position.
  with-watch [TERM, INT, TERM]: | state/ResourceState_ |
    signal-raise_ TERM
    expect-equals (BIT0 | 1 << 2) (state.wait-for-state (BIT0 | 1 << 2))
    state.clear
    signal-raise_ INT
    expect-equals BIT1 (state.wait-for-state BIT1)

// Every catchable signal can be watched and is delivered. Only raised while
// watched, since the default action of some (TSTP, TTIN, TTOU) would stop the
// test. On Windows this covers the simulated WINCH too.
test-watch-each:
  supported-names.do: | name |
    if UNCATCHABLE-NAMES.contains name: continue.do
    with-watch [signal-number_ name]: | state/ResourceState_ |
      signal-raise_ (signal-number_ name)
      expect-equals BIT0 (state.wait-for-state BIT0)

test-multiple-watchers:
  with-watch [INT, TERM]: | state1/ResourceState_ |
    with-watch [INT]: | state2/ResourceState_ |
      signal-raise_ INT
      expect-equals BIT0 (state1.wait-for-state (BIT0 | BIT1))
      expect-equals BIT0 (state2.wait-for-state BIT0)
      state1.clear
      state2.clear

      signal-raise_ TERM
      expect-equals BIT1 (state1.wait-for-state (BIT0 | BIT1))
      state1.clear
      expect-throw "DEADLINE_EXCEEDED":
        with-timeout --ms=10:
          state2.wait-for-state BIT0

    // The second watcher is gone, but the first one should still be watching.
    signal-raise_ INT
    expect-equals BIT0 (state1.wait-for-state (BIT0 | BIT1))

test-ignore:
  signal-ignore_ USR1
  // Survives since the disposition is ignore.
  signal-raise_ USR1

  with-watch [USR1]: | state/ResourceState_ |
    signal-raise_ USR1
    expect-equals BIT0 (state.wait-for-state BIT0)

  // Back to the ignore disposition.
  signal-raise_ USR1

test-ignore-chld:
  // Ignoring CHLD must not make the kernel reap children, or waiting for a
  // subprocess would hang.
  signal-ignore_ CHLD
  process := pipe.fork "sh" ["sh", "-c", "exit 3"]
  process.wait
  expect-equals 3 process.exit-code
  signal-reset_ CHLD

test-pipe:
  // The VM ignores SIGPIPE by default.
  signal-raise_ PIPE

  with-watch [PIPE]: | state/ResourceState_ |
    signal-raise_ PIPE
    expect-equals BIT0 (state.wait-for-state BIT0)

  // The VM's ignore disposition is restored.
  signal-raise_ PIPE

signal-init_:
  #primitive.signal.init

signal-watch_ group numbers:
  #primitive.signal.watch

signal-unwatch_ resource group:
  #primitive.signal.unwatch

signal-reset_ number/int:
  #primitive.signal.reset

signal-ignore_ number/int:
  #primitive.signal.ignore

signal-raise_ number/int:
  #primitive.signal.raise

signal-number_ name/string:
  #primitive.signal.number
