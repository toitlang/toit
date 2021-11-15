// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .level
import .rpc
import rpc

interface Target:
  log names/List/*<string>*/ level/int message/string tags/Map/*<string, any>*/ -> none

class DefaultTarget implements Target:
  log names/List/*<string>*/ level/int message/string tags/Map/*<string, any>*/ -> none:
    rpc.invoke RPC_SYSTEM_LOG [names, level, message, tags.map: | _ v | v.stringify]

level_name level -> string:
  if level == DEBUG_LEVEL: return "DEBUG"
  if level == INFO_LEVEL: return "INFO"
  if level == WARN_LEVEL: return "WARN"
  if level == ERROR_LEVEL: return "ERROR"
  if level == FATAL_LEVEL: return "FATAL"
  unreachable
