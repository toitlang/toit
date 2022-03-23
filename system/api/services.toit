// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services
  show
    RPC_SERVICES_MANAGER_INSTALL
    RPC_SERVICES_MANAGER_LISTEN
    RPC_SERVICES_MANAGER_UNLISTEN
    RPC_SERVICES_DISCOVER

import ..containers
import ..system_rpc_broker

class ServicesApi:
  broker_/SystemRpcBroker ::= ?
  manager_/ContainerManager ::= ?

  constructor .broker_ .manager_:
    broker_.register_procedure RPC_SERVICES_MANAGER_INSTALL:: | _ _ pid |
      manager_.service_install_manager pid

    broker_.register_procedure RPC_SERVICES_MANAGER_LISTEN:: | name _ pid |
      manager_.service_listen name pid

    broker_.register_procedure RPC_SERVICES_MANAGER_UNLISTEN:: | name |
      manager_.service_unlisten name

    broker_.register_procedure RPC_SERVICES_DISCOVER:: | name _ pid |
      manager_.service_discover name pid
