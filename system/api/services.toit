// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services
  show
    RPC_SERVICES_MANAGER_INSTALL
    RPC_SERVICES_MANAGER_LISTEN
    RPC_SERVICES_MANAGER_UNLISTEN
    RPC_SERVICES_DISCOVER

import ..services
import ..system_rpc_broker

class ServicesApi:
  broker_/SystemRpcBroker ::= ?
  manager_/ServiceDiscoveryManager ::= ?

  constructor .broker_ .manager_:
    broker_.register_procedure RPC_SERVICES_MANAGER_INSTALL:: | _ _ pid |
      manager_.install_manager pid

    broker_.register_procedure RPC_SERVICES_MANAGER_LISTEN:: | name _ pid |
      manager_.listen name pid

    broker_.register_procedure RPC_SERVICES_MANAGER_UNLISTEN:: | name |
      manager_.unlisten name

    broker_.register_procedure RPC_SERVICES_DISCOVER:: | name _ pid |
      manager_.discover name pid
