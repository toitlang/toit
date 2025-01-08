// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32.espnow
import .variants

PMK ::= espnow.Key.from-string Variant.CURRENT.espnow-password

END-TOKEN ::= "<END>"

TEST-DATA ::= [
  "In my younger and more vulnerable years",
  "my father gave me some advice",
  "that I've been turning over in my mind ever since.",
  "\"Whenever you feel like criticizing any one,\"",
  "he told me,",
  "\"just remember that all the people in this world",
  "haven't had the advantages that you've had.\"",
  "-- F. Scott Fitzgerald",
  "The Great Gatsby",
  END-TOKEN
]

CHANNEL ::= Variant.CURRENT.espnow-channel
