// Copyright (C) 2020 Toitware ApS. All rights reserved.
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

/**
The environment variables of the system.

Not available on embedded platforms.
*/
// TODO(florian): we should probably have a Map mixin and inherit all its methods.
class EnvironmentVariableMap:
  constructor.private_:

  operator [] key/string -> string:
    result := get_env_ key
    if not result: throw "ENV NOT FOUND"
    return result

  get key/string -> string?:
    return get_env_ key

  contains key/string -> bool:
    return (get key) != null


env / EnvironmentVariableMap ::= EnvironmentVariableMap.private_

get_env_ key/string -> string?:
  #primitive.core.get_env
