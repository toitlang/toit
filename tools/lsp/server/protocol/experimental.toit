// Copyright (C) 2020 Toitware ApS. All rights reserved.

import ..rpc

class Experimental extends MapWrapper:
  constructor json_map/Map: super json_map

  constructor --ubjson_rpc/bool?=null:
    map_["ubjsonRpc"] = ubjson_rpc

  /**
  Whether the RPC connection supports UBJSON.
  */
  ubjson_rpc -> bool?:
    return lookup_ "ubjsonRpc"
