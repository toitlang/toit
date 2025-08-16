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

import host.file
import .data

validate-license-id license/string -> bool:
  return LICENSE-IDS.contains license

cannonicalize-license license-text -> string:
  // Remove all spaces and lines beginning with 'Copyright' from license-text
  license-text = license-text.replace --all "\r" ""
  lines := license-text.split "\n"
  lines.map --in-place: it.replace --all " " ""
  lines.filter --in-place: not it.starts-with "Copyright"
  return lines.join ""

guess-license license-text -> string?:
  canonicalized := cannonicalize-license license-text
  KNOWN-LICENSES.do: | license-id/string text/string |
    canonicalized-known := cannonicalize-license text
    if canonicalized.starts-with canonicalized-known or
       canonicalized.ends-with canonicalized-known:
      return license-id
  return null
