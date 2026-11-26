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

/**
Variant S of the sandbox network services (experimental): TCP streams,
  optionally with TLS run by the system process, to destinations the
  container's network policy allows.
*/

import system.api.sandbox-network show SandboxSocketService

import .core
import .policy

class SandboxSocketServiceProvider extends SandboxNetworkProvider:
  constructor core/SandboxNetworkCore:
    super "system/sandbox-network/socket" core
    provides SandboxSocketService.SELECTOR --handler=this

  handle-open index/int arguments/any --gid/int --client/int -> any:
    if index != SandboxSocketService.CONNECT-INDEX: throw "INVALID_ARGUMENT"
    if arguments is not List or arguments.size != 3: throw "WRONG_OBJECT_TYPE"
    host := arguments[0]
    port := arguments[1]
    use-tls := arguments[2]
    if host is not string or port is not int or use-tls is not bool:
      throw "WRONG_OBJECT_TYPE"
    grant := core.grant gid
    // Sockets: rules with a path never apply.
    if not grant.allows host port --path=null: throw "NETWORK_DENIED"
    return open-stream_ grant:
      SandboxConnection this client core grant host port use-tls
