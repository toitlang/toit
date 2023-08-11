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
import system.api.service-discovery show ServiceDiscoveryService

class DiscoverableService:
  pid/int
  id/int
  uuid/string
  name/string
  major/int
  minor/int
  priority/int
  tags/List?
  constructor --.pid --.id --.uuid --.name --.major --.minor --.priority --.tags:

class SystemServiceManager extends ServiceProvider
    implements ServiceDiscoveryService ServiceHandler:
  service-managers_/Map ::= {:}  // Map<int, Set<int>>

  services-by-pid_/Map ::= {:}   // Map<int, Map<int, DiscoverableService>>>
  services-by-uuid_/Map ::= {:}  // Map<string, List<DiscoverableService>>

  signal_/monitor.Signal ::= monitor.Signal

  constructor:
    super "system/service-discovery" --major=0 --minor=1 --patch=1
    provides ServiceDiscoveryService.SELECTOR --handler=this --id=0
    install

  handle index/int arguments/any --gid/int --client/int -> any:
    pid := pid --client=client
    if index == ServiceDiscoveryService.DISCOVER-INDEX:
      return discover arguments[0] --wait=arguments[1]
    if index == ServiceDiscoveryService.WATCH-INDEX:
      return watch pid arguments
    if index == ServiceDiscoveryService.LISTEN-INDEX:
      return listen pid arguments
    if index == ServiceDiscoveryService.UNLISTEN-INDEX:
      return unlisten pid arguments
    unreachable

  listen pid/int arguments/List -> none:
    services := services-by-pid_.get pid --init=(: {:})
    id := arguments[0]
    if services.contains id: throw "Service id $id is already in use"

    uuid := arguments[1]
    service := DiscoverableService
        --pid=pid
        --id=id
        --uuid=uuid
        --name=arguments[2]
        --major=arguments[3]
        --minor=arguments[4]
        --priority=arguments[5]
        --tags=arguments[6]
    services[id] = service

    // Register the service based on its uuid and sort the all services
    // with the same uuid by descending priority.
    uuids := services-by-uuid_.get uuid --init=(: [])
    uuids.add service
    uuids.sort --in-place: | a b | b.priority.compare-to a.priority

    // Register the process as a service manager and signal
    // anyone waiting for services to appear.
    service-managers_.get pid --init=(: {})
    signal_.raise

  unlisten pid/int id/int -> none:
    services := services-by-pid_.get pid
    if not services: return
    service := services.get id
    if not service: return
    services.remove id

    uuid := service.uuid
    uuids := services-by-uuid_.get uuid
    if uuids:
      uuids.remove service
      if uuids.is-empty: services-by-uuid_.remove uuid

    if not services.is-empty: return
    service-managers_.remove pid
    services-by-pid_.remove pid

  discover uuid/string --wait/bool -> List?:
    services/List? := null
    if wait:
      signal_.wait:
        services = services-by-uuid_.get uuid
        services != null
    else:
      services = services-by-uuid_.get uuid
      if not services: return null

    // TODO(kasper): Consider keeping the list of
    // services in a form that is ready to send
    // back without any transformations.
    result := Array_ 7 * services.size
    index := 0
    services.do: | service/DiscoverableService |
      result[index++] = service.pid
      result[index++] = service.id
      result[index++] = service.name
      result[index++] = service.major
      result[index++] = service.minor
      result[index++] = service.priority
      result[index++] = service.tags
    return result

  watch pid/int target/int -> none:
    if pid == target: return
    processes := service-managers_.get pid
    if processes: processes.add target

  on-process-stop pid/int -> none:
    services := services-by-pid_.get pid
    // Iterate over a copy of the values, so we can manipulate the
    // underlying map in the call to unlisten.
    if services: services.values.do: | service/DiscoverableService |
      unlisten service.pid service.id
    // Tell service managers about the termination.
    service-managers_.do: | manager/int processes/Set |
      if not processes.contains pid: continue.do
      processes.remove pid
      process-send_ manager SYSTEM-RPC-NOTIFY-TERMINATED_ pid

  listen id/int uuid/string -> none
      --name/string
      --major/int
      --minor/int
      --priority/int
      --tags/List:
    unreachable  // <-- TODO(kasper): nasty

  unlisten id/int -> none:
    unreachable  // <-- TODO(kasper): nasty

  watch target/int -> none:
    unreachable  // <-- TODO(kasper): nasty
