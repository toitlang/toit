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

import system.services
  show
    ServiceDefinition
    SERVICES_MANAGER_NOTIFY_ADD_PROCESS
    SERVICES_MANAGER_NOTIFY_REMOVE_PROCESS

import monitor
import system.api.service_discovery show ServiceDiscoveryService

// Internal limits.
SERVICE_ID_LIMIT_ /int ::= 0x3fff_ffff

class SystemServiceManager extends ServiceDefinition implements ServiceDiscoveryService:
  service_managers_/Map ::= {:}  // Map<int, Set<int>>

  services_/Map ::= {:}          // Map<int, int>
  services_by_pid_/Map ::= {:}   // Map<int, Set<int>>

  // ...
  services_by_uuid_/Map ::= {:}  // Map<string, int>

  signal_/monitor.Signal ::= monitor.Signal

  constructor:
    super "system/service-discovery" --major=0 --minor=1 --patch=1
    provides ServiceDiscoveryService.UUID ServiceDiscoveryService.MAJOR ServiceDiscoveryService.MINOR
    install

  handle pid/int client/int index/int arguments/any -> any:
    if index == ServiceDiscoveryService.DISCOVER_INDEX:
      return discover arguments[0] arguments[1] pid
    if index == ServiceDiscoveryService.LISTEN_INDEX:
      return listen arguments pid
    if index == ServiceDiscoveryService.UNLISTEN_INDEX:
      return unlisten arguments
    unreachable

  listen uuid/string pid/int -> int:
    if services_by_uuid_.contains uuid:
      throw "Already registered service:$uuid"
    id := assign_service_id_ pid
    services_by_uuid_[uuid] = id
    service_managers_.get pid --init=(: {})
    ids := services_by_pid_.get pid --init=(: {})
    ids.add id
    signal_.raise
    return id

  unlisten id/int -> none:
    pid := services_.get id
    if not pid: return

    // TODO(kasper): Clean up the discovery table.
    // services_by_uuid_.remove uuid

    ids := services_by_pid_.get pid
    if not ids: return
    ids.remove id
    if not ids.is_empty: return
    service_managers_.remove pid
    services_by_pid_.remove pid

  discover uuid/string wait/bool pid/int -> int?:
    target/int? := null
    if wait:
      signal_.wait:
        target = services_by_uuid_.get uuid
        target != null
    else:
      target = services_by_uuid_.get uuid
      if not target: return null
    processes := service_managers_[target]
    if processes:
      processes.add pid
      process_send_ target SYSTEM_RPC_NOTIFY_ [SERVICES_MANAGER_NOTIFY_ADD_PROCESS, pid]
    return target

  on_process_stop pid/int -> none:
    ids := services_by_pid_.get pid
    // Iterate over a copy of the uuids, so we can manipulate the
    // underlying set in the call to unlisten.
    if ids: (Array_.from ids).do: unlisten it
    // Tell service managers about the termination.
    service_managers_.do: | manager/int processes/Set |
      if not processes.contains pid: continue.do
      processes.remove pid
      process_send_ manager SYSTEM_RPC_NOTIFY_ [SERVICES_MANAGER_NOTIFY_REMOVE_PROCESS, pid]

  assign_service_id_ pid/int -> int:
    while true:
      guess := random SERVICE_ID_LIMIT_
      if services_.contains guess: continue
      services_[guess] = pid
      return guess

  discover uuid/string wait/bool -> int?:
    unreachable  // <-- TODO(kasper): nasty

  listen uuid/string -> none:
    unreachable  // <-- TODO(kasper): nasty
