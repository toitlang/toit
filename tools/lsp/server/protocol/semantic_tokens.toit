// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
