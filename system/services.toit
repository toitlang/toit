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
import system.services show ServiceProvider ServiceHandler ServiceResource
import system.api.service-discovery show ServiceDiscoveryService
import system.api.print show PrintService
import system.api.containers show ContainerService

/**
Services with this tag that are provided by the system process are only
  discovered by sandboxed (untrusted) clients.
*/
TAG-SANDBOX-ONLY ::= "sandbox-only"

/**
Tag added to every service provided by a sandboxed process, so clients can
  deny such providers with a restricted service selector.
*/
TAG-UNTRUSTED-PROVIDER ::= "untrusted-provider"

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

class DiscoveryResource extends ServiceResource:
  uuid/string
  manager/SystemServiceManager

  constructor .uuid .manager client/int:
    super manager client --notifiable

  on-closed -> none:
    list := manager.waiting_[uuid]
    if list.size == 1:
      assert: list[0] == this
      manager.waiting_.remove uuid
    else:
      list.remove this

class SystemServiceManager extends ServiceProvider
    implements ServiceDiscoveryService ServiceHandler:
  service-managers_/Map ::= {:}  // Map<int, Set<int>>

  services-by-pid_/Map ::= {:}   // Map<int, Map<int, DiscoverableService>>>
  services-by-uuid_/Map ::= {:}  // Map<string, List<DiscoverableService>>

  waiting_/Map ::= {:}  // Map<uuid, List<DiscoveryResource>>

  constructor:
    super "system/service-discovery" --major=0 --minor=1 --patch=1
    provides ServiceDiscoveryService.SELECTOR --handler=this --id=0
    install
    (SandboxPrintServiceProvider).install

  // Every process needs service discovery, sandboxed ones included.
  accepts-untrusted-clients -> bool:
    return true

  handle index/int arguments/any --gid/int --client/int -> any:
    pid := pid --client=client
    if index == ServiceDiscoveryService.DISCOVER-INDEX:
      return discover arguments[0] --wait=arguments[1] client --pid=pid
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
    service-priority/int := arguments[5]
    service-tags/List? := arguments[6]
    if is-untrusted_ pid:
      // Sandboxed providers can't take over services from trusted
      // providers, and clients can recognize (and deny) them.
      service-priority = ServiceProvider.PRIORITY-UNPREFERRED-STRONGLY
      service-tags = service-tags ? (service-tags + [TAG-UNTRUSTED-PROVIDER]) : [TAG-UNTRUSTED-PROVIDER]
    service := DiscoverableService
        --pid=pid
        --id=id
        --uuid=uuid
        --name=arguments[2]
        --major=arguments[3]
        --minor=arguments[4]
        --priority=service-priority
        --tags=service-tags
    services[id] = service

    // Register the service based on its uuid and sort the all services
    // with the same uuid by descending priority.
    uuids := services-by-uuid_.get uuid --init=(: [])
    uuids.add service
    uuids.sort --in-place: | a b | b.priority.compare-to a.priority

    // If anyone is waiting for this service, signal them.
    waiting_.get uuid --if-present=: | resources/List |
      resources.do: | resource/DiscoveryResource |
        resource.notify_ (array-of-services_ [service])

    // Register the process as a service manager and signal
    // anyone waiting for services to appear.
    service-managers_.get pid --init=(: {})

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
    services-by-pid_.remove pid

  discover uuid/string --wait/bool client/int --pid/int -> List:
    services/List? := null
    resource-serialized := null
    if wait:
      resource := DiscoveryResource uuid this client
      (waiting_.get uuid --init=: []).add resource
      resource-serialized = resource.serialize-for-rpc
    services = services-by-uuid_.get uuid
    if services:
      untrusted := is-untrusted_ pid
      system-pid := Process.current.id
      if not untrusted:
        // Hide the system services that only exist for sandboxed clients.
        services = services.filter: | service/DiscoverableService |
          not (service.pid == system-pid and service.tags and service.tags.contains TAG-SANDBOX-ONLY)
      else:
        // Discovery is how a sandboxed process gets the capability to send
        // messages to a provider: grant it for every discovered provider.
        services.do: | service/DiscoverableService |
          process-grant-send_ pid service.pid
      if services.is-empty: services = null
    return [array-of-services_ services, resource-serialized]

  static is-untrusted_ pid/int -> bool:
    return (process-policy_ pid) == ContainerService.POLICY-UNTRUSTED

  // TODO(kasper): Consider keeping the list of
  // services in a form that is ready to send
  // back without any transformations.
  static array-of-services_ services/List? -> Array_?:
    if not services: return null
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
    // A watch can arrive after the stop notification has already been handled.
    // Report that terminal state now rather than retaining an unwakeable watch.
    error := catch --unwind=(: it != "INVALID_ARGUMENT"):
      process-get-priority_ target
    if error:
      process-send_ pid SYSTEM-RPC-NOTIFY-TERMINATED_ target
      return
    (service-managers_.get pid --init=(: {})).add target

  on-process-stop pid/int -> none:
    service-managers_.remove pid
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

  discover uuid/string --wait/bool -> List:
    unreachable  // <-- TODO(kasper): nasty

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

/**
A print service in the system process for sandboxed (untrusted) clients.

Sandboxed processes can't write to stdout themselves, so their $print
  goes through this service. It is only discovered by sandboxed clients;
  other processes keep printing directly.
*/
class SandboxPrintServiceProvider extends ServiceProvider implements PrintService ServiceHandler:
  static MAX-MESSAGE-SIZE ::= 4096

  constructor:
    super "system/print/sandbox" --major=0 --minor=1 --tags=[TAG-SANDBOX-ONLY]
    provides PrintService.SELECTOR --handler=this

  accepts-untrusted-clients -> bool:
    return true

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PrintService.PRINT-INDEX:
      if arguments is not string: throw "WRONG_OBJECT_TYPE"
      return print arguments
    unreachable

  print message/string -> none:
    if message.size > MAX-MESSAGE-SIZE:
      // Cut at a character boundary. UTF-8 continuation bytes are
      // 0b10xx_xxxx.
      end := MAX-MESSAGE-SIZE
      while end > 0 and (message.at --raw end) & 0xc0 == 0x80: end--
      message = message[..end] + "..."
    write-on-stdout_ message true

/**
Returns the policy kind of the process with the given $pid, or -1 if
  there is no such process.
*/
process-policy_ pid/int -> int:
  #primitive.core.process-policy

/**
Allows the process with the given $pid to send messages to $target, if the
  policy of $pid restricts messaging. Only the system process may call this.

Throws QUOTA_EXCEEDED if the allowed-target set of the process' group is
  full.
*/
process-grant-send_ pid/int target/int -> bool:
  #primitive.core.process-grant-send
