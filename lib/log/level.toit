// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

DEBUG-LEVEL ::= 0
INFO-LEVEL  ::= 1
WARN-LEVEL  ::= 2
ERROR-LEVEL ::= 3
FATAL-LEVEL ::= 4

level-name level/int -> string:
  if level == DEBUG-LEVEL: return "DEBUG"
  if level == INFO-LEVEL: return "INFO"
  if level == WARN-LEVEL: return "WARN"
  if level == ERROR-LEVEL: return "ERROR"
  if level == FATAL-LEVEL: return "FATAL"
  unreachable
