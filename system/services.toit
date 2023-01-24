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
    ServiceManager_

import monitor
import system.api.service_discovery show ServiceDiscoveryService

class DiscoverableService:
  pid/int
  id/int
  uuid/string
  constructor --.pid --.id --.uuid:

class SystemServiceManager extends ServiceDefinition implements ServiceDiscoveryService:
  service_managers_/Map ::= {:}  // Map<int, Set<int>>

  services_by_pid_/Map ::= {:}   // Map<int, Map<int, DiscoverableService>>>
  services_by_uuid_/Map ::= {:}  // Map<string, DiscoverableService>

  signal_/monitor.Signal ::= monitor.Signal

  constructor:
    super "system/service-discovery" --major=0 --minor=1 --patch=1
    provides ServiceDiscoveryService.UUID ServiceDiscoveryService.MAJOR ServiceDiscoveryService.MINOR
    // TODO(kasper): This is pretty nasty. It is really
    // just installing under a well-defined service id
    // so the client doesn't have to guess it.
    pid := Process.current.id
    id := 0
    services_by_pid_[pid] = {
      id: DiscoverableService --pid=pid --id=id --uuid=ServiceDiscoveryService.UUID
    }
    _manager_ = ServiceManager_.instance
    _manager_.services_[id] = this

  handle pid/int client/int index/int arguments/any -> any:
    if index == ServiceDiscoveryService.DISCOVER_INDEX:
      return discover arguments[0] arguments[1]
    if index == ServiceDiscoveryService.WATCH_INDEX:
      return watch pid arguments
    if index == ServiceDiscoveryService.LISTEN_INDEX:
      return listen pid arguments[0] arguments[1]
    if index == ServiceDiscoveryService.UNLISTEN_INDEX:
      return unlisten pid arguments
    unreachable

  listen pid/int id/int uuid/string -> none:
    services := services_by_pid_.get pid --init=(: {:})
    if services.contains id:
      throw "Already registered service:$id"
    service_managers_.get pid --init=(: {})
    // TODO(kasper): Change this check.
    if services_by_uuid_.contains uuid:
      throw "Already registered service:$uuid"

    service := DiscoverableService --pid=pid --id=id --uuid=uuid
    services[id] = service
    services_by_uuid_[uuid] = service
    signal_.raise

  unlisten pid/int id/int -> none:
    services := services_by_pid_.get pid
    if not services: return
    service := services.get id
    if not service: return

    services.remove id
    services_by_uuid_.remove service.uuid
    if not services.is_empty: return
    service_managers_.remove pid
    services_by_pid_.remove pid

  discover uuid/string wait/bool -> List?:
    service/DiscoverableService? := null
    if wait:
      signal_.wait:
        service = services_by_uuid_.get uuid
        service != null
    else:
      service = services_by_uuid_.get uuid
      if not service: return null
    return [service.pid, service.id]

  watch pid/int target/int -> none:
    if pid == target: return
    processes := service_managers_.get pid
    if processes: processes.add target

  on_process_stop pid/int -> none:
    services := services_by_pid_.get pid
    // Iterate over a copy of the values, so we can manipulate the
    // underlying map in the call to unlisten.
    if services: services.values.do: | service/DiscoverableService |
      unlisten service.pid service.id
    // Tell service managers about the termination.
    service_managers_.do: | manager/int processes/Set |
      if not processes.contains pid: continue.do
      processes.remove pid
      process_send_ manager SYSTEM_RPC_NOTIFY_TERMINATED_ pid

  listen id/int uuid/string -> none:
    unreachable  // <-- TODO(kasper): nasty

  unlisten id/int -> none:
    unreachable  // <-- TODO(kasper): nasty

  watch target/int -> none:
    unreachable  // <-- TODO(kasper): nasty
