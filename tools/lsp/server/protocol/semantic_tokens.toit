// Copyright (C) 2020 Toitware ApS.
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

class SemanticTokensParams extends MapWrapper:
  constructor json_map/Map: super json_map

  /** The document we need the semantic tokens for. */
  text_document -> TextDocumentIdentifier:
    return at_ "textDocument": TextDocumentIdentifier it

class SemanticTokens extends MapWrapper:
  constructor
      --data     /List/*int*/:
    map_["data"] = data
