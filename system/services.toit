// Copyright (C) 2022 Toitware ApS.
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

import system.discovery
  show
    ServiceDiscovery

import system.services
  show
    ServiceDefinition
    ServiceManager_
    SERVICES_MANAGER_NOTIFY_OPEN_CLIENT
    SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT

class ServiceDiscoveryDefinition extends ServiceDefinition implements ServiceDiscovery:
  service_managers_/Map ::= {:}     // Map<int, Set<int>>
  services_by_id_/Map ::= {:}       // Map<int, Set<string>>
  services_by_name_/Map ::= {:}     // Map<name, int>

  constructor:
    super ServiceDiscovery.NAME --major=ServiceDiscovery.MAJOR --minor=ServiceDiscovery.MINOR

  install:
    // TODO(kasper): Share code. This is completely reimplemented here.
    manager_ = ServiceManager_.instance
    procedure_ = manager_.install this
    names_.do:
      manager_.services_by_name_[it] = this
      listen it current_process_  // <--- this is the only thing that doesn't work directly.

  handle client/int index/int arguments/any -> any:
    if index == ServiceDiscovery.DISCOVER_INDEX:
      return discover arguments client
    if index == ServiceDiscovery.LISTEN_INDEX:
      return listen arguments client
    if index == ServiceDiscovery.UNLISTEN_INDEX:
      return unlisten arguments
    unreachable

  listen name/string pid/int -> none:
    service_managers_.get pid --init=(: {})
    if services_by_name_.contains name:
      throw "Already registered service:$name"
    services_by_name_[name] = pid
    names := services_by_id_.get pid --init=(: {})
    names.add name

  unlisten name/string -> none:
    // TODO(kasper): Clean up the service managers set when the
    // last of its services go away.
    pid := services_by_name_.get name
    if not pid: return
    services_by_name_.remove name
    names := services_by_id_.get pid
    if names:
      names.remove name
      if names.is_empty: services_by_id_.remove pid

  discover name/string pid/int -> int:
    target := services_by_name_.get name
    if not target:
      throw "Cannot find service:$name"
    clients := service_managers_[target]
    if clients:
      clients.add pid
      process_send_ target SYSTEM_RPC_NOTIFY_ [SERVICES_MANAGER_NOTIFY_OPEN_CLIENT, pid]
    return target

  on_process_stop pid/int -> none:
    names := services_by_id_.get pid
    if names: names.do: unlisten it
    // Tell service managers about the termination.
    service_managers_.remove pid
    service_managers_.do: | manager clients |
      if clients.contains pid:
        process_send_ manager SYSTEM_RPC_NOTIFY_ [SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT, pid]

  discover name/string -> int:
    unreachable  // <-- TODO(kasper): nasty

  listen name/string -> none:
    unreachable  // <-- TODO(kasper): nasty
