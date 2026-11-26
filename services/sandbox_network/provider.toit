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

import .core
import .http-service
import .socket-service

/**
Installs the sandbox network services (variant S with $socket, variant H
  with $http) in this process and serves them until the process ends.

The process must run as a trusted container: it uses the network itself
  (sockets, DNS, TLS) and asks the system process for the network policies
  of its clients' containers.
*/
run-sandbox-network --socket/bool=true --http/bool=true -> none:
  core := SandboxNetworkCore
  if socket: (SandboxSocketServiceProvider core).install
  if http: (SandboxHttpServiceProvider core).install
  // The providers serve requests in tasks of their own; keep the process.
  while true: sleep --ms=1_000_000
