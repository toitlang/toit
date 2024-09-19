// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import .builder

LIBRARIES-FUNDAMENTAL ::= {"core", "crypto", "io", "log", "math", "monitor", "system"}
LIBRARIES-JUST-THERE ::= {"expect", "device", "gpio", "i2c", "serial", "uuid"}

LIBRARIES-HIDDEN ::= [
  "coap", "cron", "debug", "experimental", "protogen", "rpc",
  "service_registry", "service-registry", "services", "words"
]

category-for-sdk-library segments/List -> string:
  if segments.size == 1:
    // Not really a sub category, but currently we have this
    // 'lib' segment/library that shouldn't be there.
    return Library.CATEGORY-SUB

  // Segments start with "lib".
  first := segments[1]
  if LIBRARIES-FUNDAMENTAL.contains first: return Library.CATEGORY-FUNDAMENTAL
  if LIBRARIES-JUST-THERE.contains first: return Library.CATEGORY-JUST-THERE
  return Library.CATEGORY-MISC

is-sdk-library-hidden segments/List -> bool:
  first := segments[1]
  if first == "encoding" and segments.size == 3 and segments[2] == "tpack": return true
  return LIBRARIES-HIDDEN.contains first
