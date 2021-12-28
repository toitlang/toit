// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
