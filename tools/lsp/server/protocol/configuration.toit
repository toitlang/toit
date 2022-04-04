// Copyright (C) 2019 Toitware ApS.
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
