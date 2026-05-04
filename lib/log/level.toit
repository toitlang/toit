// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

TRACE-LEVEL ::= 0
DEBUG-LEVEL ::= 1
INFO-LEVEL  ::= 2
WARN-LEVEL  ::= 3
ERROR-LEVEL ::= 4
FATAL-LEVEL ::= 5

level-name level/int -> string:
  if level == TRACE-LEVEL: return "TRACE"
  if level == DEBUG-LEVEL: return "DEBUG"
  if level == INFO-LEVEL: return "INFO"
  if level == WARN-LEVEL: return "WARN"
  if level == ERROR-LEVEL: return "ERROR"
  if level == FATAL-LEVEL: return "FATAL"
  unreachable
