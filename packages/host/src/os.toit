// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

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
