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

class ArchiveParams extends MapWrapper:

  /**
  Bundle request from the LSP server.

  Parameters:
  - uri: entry uri
  */
  constructor json_map/Map: super json_map

  uri -> string?:
    return lookup_ "uri"

  uris -> List?:
    return lookup_ "uris"

  include_sdk -> bool?:
    return lookup_ "includeSdk"

class FetchSdkFileParams extends MapWrapper:

  /**
  FetchSDKFile from the LSP server.

  Parameters:
  - path: path of the sdk file
  */
  constructor json_map/Map: super json_map

  path -> string:
    return at_ "path"

class SnapshotBundleParams extends MapWrapper:

  /**
  Snapshot params from the LSP server.

  Parameters:
  - uri: entry uri
  */
  constructor json_map/Map: super json_map

  uri -> string:
    return at_ "uri"
