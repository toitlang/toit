// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .type-migration-lib as lib

class Pin:
class SubPin extends Pin:

interface Reader:
  read -> none

class StringReader implements Reader:
  read -> none:

// __TYPE-MIGRATION__ rx: Pin. Deprecated. Provide an integer instead.
// __TYPE-MIGRATION__ rx: int
// __TYPE-MIGRATION__ tx: Pin. Deprecated. Provide an integer instead.
// __TYPE-MIGRATION__ tx: int
create-uart --rx/any --tx/any=null:

// __TYPE-MIGRATION__ data: string?
consume-nullable data/any:

// __TYPE-MIGRATION__ in: Reader. Deprecated.
// __TYPE-MIGRATION__ in: int
consume-reader in/any:

// __TYPE-MIGRATION__ port: lib.Port
consume-port port/any:

/// Some toitdoc.
// __TYPE-MIGRATION__ x: int
mixed-with-toitdoc x/any:

class Uart:
  // __TYPE-MIGRATION__ pin: Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ pin: int
  configure pin/any:

// __TYPE-MIGRATION__
missing-name x/any:

// __TYPE-MIGRATION__ x int
missing-colon x/any:

// __TYPE-MIGRATION__ x:
missing-type x/any:

// __TYPE-MIGRATION__ x: int and then junk
unexpected-text x/any:

// __TYPE-MIGRATION__ y: int
wrong-name x/any:

// __TYPE-MIGRATION__ x: NotAType
unresolved-type x/any:

// __TYPE-MIGRATION__ x: int
not-an-any-parameter x/string:

// __TYPE-MIGRATION__ b: int
on-block-parameter x/any [b]:

// __TYPE-MIGRATION__ x: int

unattached x/any:

main:
  pin := Pin
  sub := SubPin
  untyped/any := 42

  create-uart --rx=pin --tx=18      // Warning for rx: deprecated Pin.
  create-uart --rx=17 --tx=18       // OK.
  create-uart --rx=17.5 --tx=18     // Error: float not allowed.
  create-uart --rx=null --tx=null   // Error for rx (no default value); OK for tx.
  create-uart --rx=untyped --tx=1   // OK: 'any' argument passes silently.
  create-uart --rx=sub --tx=1       // Warning: subclass of deprecated Pin.

  consume-nullable "str"            // OK.
  consume-nullable null             // OK: nullable alternative.
  consume-nullable 5                // Error.

  consume-reader StringReader       // Warning: implements deprecated interface.
  consume-reader 5                  // OK.
  consume-reader "x"                // Error.

  consume-port lib.Port             // OK.
  consume-port 5                    // Error.

  mixed-with-toitdoc 7              // OK.
  mixed-with-toitdoc "bad"          // Error.

  uart := Uart
  uart.configure pin                // Warning: deprecated Pin on virtual call.
  uart.configure 17                 // OK.
  uart.configure "bad"              // Error.
