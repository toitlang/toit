// Copyright (C) 2026 Toit contributors.
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

import ..rpc
import .document

class Hover extends MapWrapper:
  constructor.from-json map/Map: super map

  constructor --contents/string --range/Range?=null:
    map_["contents"] = {"kind": "markdown", "value": contents}
    if range: map_["range"] = range.map_

  contents -> Map:
    return at_ "contents"

  range -> Range?:
    return at_ "range": Range.from-map it
