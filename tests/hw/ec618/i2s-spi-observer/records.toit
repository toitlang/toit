// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
import expect show *

fields parts/List start/int -> Map:
  result := {:}
  parts[start..].do: |part/string|
    pair := part.split "="
    expect-equals 2 pair.size
    expect (not result.contains pair[0])
    result[pair[0]] = pair[1]
  return result

number values/Map key/string -> int:
  return int.parse values[key]
