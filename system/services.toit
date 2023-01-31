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

import monitor
import system.services show ServiceProvider ServiceHandler
import system.api.service_discovery show ServiceDiscoveryService

class DiscoverableService:
  pid/int
  id/int
  name/string
  uuid/string
  priority/int
  constructor --.pid --.id --.name --.uuid --.priority:

class SystemServiceManager extends ServiceProvider implements ServiceDiscoveryService ServiceHandler:
  service_managers_/Map ::= {:}  // Map<int, Set<int>>

  services_by_pid_/Map ::= {:}   // Map<int, Map<int, DiscoverableService>>>
  services_by_uuid_/Map ::= {:}  // Map<string, List<DiscoverableService>>

  signal_/monitor.Signal ::= monitor.Signal

  constructor:
    super "system/service-discovery" --major=0 --minor=1 --patch=1
    provides ServiceDiscoveryService.UUID ServiceDiscoveryService.MAJOR ServiceDiscoveryService.MINOR
        --handler=this
        --id=0
    install

  handle pid/int client/int index/int arguments/any -> any:
    if index == ServiceDiscoveryService.DISCOVER_INDEX:
      return discover arguments[0] arguments[1]
    if index == ServiceDiscoveryService.WATCH_INDEX:
      return watch pid arguments
    if index == ServiceDiscoveryService.LISTEN_INDEX:
      return listen pid arguments[0] arguments[1] arguments[2] arguments[3]
    if index == ServiceDiscoveryService.UNLISTEN_INDEX:
      return unlisten pid arguments
    unreachable

  listen pid/int id/int name/string uuid/string priority/int -> none:
    services := services_by_pid_.get pid --init=(: {:})
    if services.contains id: throw "Service id $id is already in use"

    service := DiscoverableService
        --pid=pid
        --id=id
        --name=name
        --uuid=uuid
        --priority=priority
    services[id] = service

    // Register the service based on its uuid and sort the all services
    // with the same uuid by descending priority.
    uuids := services_by_uuid_.get uuid --init=(: [])
    uuids.add service
    uuids.sort --in_place: | a b | b.priority.compare_to a.priority

    // Register the process as a service manager and signal
    // anyone waiting for services to appear.
    service_managers_.get pid --init=(: {})
    signal_.raise

  unlisten pid/int id/int -> none:
    services := services_by_pid_.get pid
    if not services: return
    service := services.get id
    if not service: return
    services.remove id

    uuid := service.uuid
    uuids := services_by_uuid_.get uuid
    if uuids:
      uuids.remove service
      if uuids.is_empty: services_by_uuid_.remove uuid

    if not services.is_empty: return
    service_managers_.remove pid
    services_by_pid_.remove pid

  discover uuid/string wait/bool -> List?:
    services/List? := null
    if wait:
      signal_.wait:
        services = services_by_uuid_.get uuid
        services != null
    else:
      services = services_by_uuid_.get uuid
      if not services: return null

    // TODO(kasper): Consider keeping the list of
    // services in a form that is ready to send
    // back without any transformations.
    result := Array_ 4 * services.size
    index := 0
    services.do: | service/DiscoverableService |
      result[index++] = service.pid
      result[index++] = service.id
      result[index++] = service.priority
      result[index++] = service.name
    return result

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

  listen id/int name/string uuid/string priority/int -> none:
    unreachable  // <-- TODO(kasper): nasty

  unlisten id/int -> none:
    unreachable  // <-- TODO(kasper): nasty

  watch target/int -> none:
    unreachable  // <-- TODO(kasper): nasty
