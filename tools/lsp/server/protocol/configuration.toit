// Copyright (C) 2019 Toitware ApS. All rights reserved.

import ..rpc

class ConfigurationParams extends MapWrapper:

  /**
  Creates the parameters for a configuration request.

  Parameters:
  - [items]: the requested configurations.
  */
  constructor
      --items /List/*<ConfigurationItem>*/:
    map_["items"] = items

class ConfigurationItem extends MapWrapper:

  /**
  Creates an item for a configuration request.

  Parameters:
  - [scope_uri]: the scope to get the configuration section for.
  - [section]: the configuration section asked for.
  */
  constructor
      --scope_uri /string? = null
      --section   /string? = null:
    map_["scopeUri"] = scope_uri
    map_["section"]  = section
