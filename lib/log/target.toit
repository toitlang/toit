// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .level

interface Target:
  log names/List/*<string>*/ level/int message/string tags/Map/*<string, any>*/ -> none

class DefaultTarget implements Target:
  log names/List/*<string>*/ level/int message/string tags/Map/*<string, any>*/ -> none:
    names_string ::= names.is_empty ? "" : "[$(names.join ",")] "
    tags_string := ""
    if not tags.is_empty:
      first := true
      tags.do: | key value |
        if not first: tags_string += ","
        tags_string += " $key=$value"
        first = false
    print "$names_string$(level_name level): $message$tags_string"

level_name level -> string:
  if level == DEBUG_LEVEL: return "DEBUG"
  if level == INFO_LEVEL: return "INFO"
  if level == WARN_LEVEL: return "WARN"
  if level == ERROR_LEVEL: return "ERROR"
  if level == FATAL_LEVEL: return "FATAL"
  unreachable
