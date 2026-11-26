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

import host.file
import host.os
import tls

import ...containers
import ...sandbox-network.core
import ...sandbox-network.http-service
import ...sandbox-network.socket-service

/**
Installs the sandbox network services (experimental) of the host.

The services verify TLS servers against the root certificates installed
  in the system process. On the host, $ROOTS-VARIABLE can name a PEM file
  with one more root certificate (for tests with a local TLS server).
*/
install-sandbox-network manager/ContainerManager -> none:
  roots := os.env.get ROOTS-VARIABLE
  if roots: (tls.RootCertificate (file.read-contents roots)).install
  core := SandboxNetworkCore --grant-for=:: | gid/int |
    container := manager.lookup-container gid
    container and container.network-grant
  (SandboxSocketServiceProvider core).install
  (SandboxHttpServiceProvider core).install

ROOTS-VARIABLE ::= "TOIT_SANDBOX_NETWORK_ROOTS"
