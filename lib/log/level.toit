// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

DEBUG_LEVEL ::= 0
INFO_LEVEL  ::= 1
WARN_LEVEL  ::= 2
ERROR_LEVEL ::= 3
FATAL_LEVEL ::= 4

level_name level/int -> string:
  if level == DEBUG_LEVEL: return "DEBUG"
  if level == INFO_LEVEL: return "INFO"
  if level == WARN_LEVEL: return "WARN"
  if level == ERROR_LEVEL: return "ERROR"
  if level == FATAL_LEVEL: return "FATAL"
  unreachable
