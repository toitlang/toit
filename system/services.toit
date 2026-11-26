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
import system.services show ServiceProvider ServiceHandler ServiceResource TAG-UNTRUSTED-PROVIDER ServiceManager_
import system.api.service-discovery show ServiceDiscoveryService
import system.api.print show PrintService
import system.api.containers show ContainerService

/**
Services with this tag that are provided by the system process are only
  discovered by sandboxed (untrusted) clients.
*/
TAG-SANDBOX-ONLY ::= "sandbox-only"

class DiscoverableService:
  pid/int
  id/int
  uuid/string
  name/string
  major/int
  minor/int
  priority/int
  tags/List?
  // Whether the provider serves sandboxed (untrusted) clients.
  accepts-untrusted/bool
  constructor --.pid --.id --.uuid --.name --.major --.minor --.priority --.tags --.accepts-untrusted:

class DiscoveryResource extends ServiceResource:
  uuid/string
  manager/SystemServiceManager
  pid/int
  // Whether the waiting process is sandboxed (untrusted).
  untrusted/bool
  // Whether the waiting process opted in to providers in sandboxes.
  untrusted-providers/bool
  // Whether the waiting process may use the service (see
  // $SystemServiceManager.sandbox-may-use_); always true for trusted ones.
  allowed/bool

  constructor .uuid .manager client/int --.pid --.untrusted --.untrusted-providers --.allowed:
    super manager client --notifiable
    manager.waiting-by-pid_.update pid --init=0: it + 1

  on-closed -> none:
    count := manager.waiting-by-pid_.get pid --if-absent=: 0
    if count <= 1:
      manager.waiting-by-pid_.remove pid
    else:
      manager.waiting-by-pid_[pid] = count - 1
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
  waiting-by-pid_/Map ::= {:}  // Map<int, int>

  // Limits for sandboxed (untrusted) processes. Everything they register
  // here lives in the system process, which has no heap limit, so without
  // them a sandbox could exhaust the memory of the whole system.
  static MAX-UNTRUSTED-SERVICES ::= 16     // Registered services per process.
  static MAX-UNTRUSTED-WAITING ::= 16      // Pending discoveries per process.
  static MAX-UNTRUSTED-STRING-SIZE ::= 128 // Size of a uuid, name or tag.
  static MAX-UNTRUSTED-TAGS ::= 8

  /**
  Called with the group id of a sandboxed process that registers a
    service; returns whether its launch policy grants it to provide
    services (see $ContainerService.POLICY-GRANT-PROVIDE-SERVICES). Set
    by the container manager. Without it, sandboxes can't provide
    services.
  */
  may-provide-services/Lambda? := null

  /**
  Called with the group id of a sandboxed process and a service uuid;
    returns whether the launch policy of its container lists the service
    (see $ContainerService.POLICY-SERVICES-INDEX). Set by the container
    manager. Without it, sandboxes can only use the services in
    $ALWAYS-AVAILABLE.
  */
  may-use-service/Lambda? := null

  /** The services every sandbox may use: discovery and printing. */
  static ALWAYS-AVAILABLE ::= [
    ServiceDiscoveryService.SELECTOR.uuid,
    PrintService.SELECTOR.uuid,
  ]

  constructor:
    super "system/service-discovery" --major=0 --minor=1 --patch=1
    provides ServiceDiscoveryService.SELECTOR --handler=this --id=0
    install
    (SandboxPrintServiceProvider).install
    // Sandboxes can send messages to the system process without
    // discovering its providers first, so the providers in this process
    // check the allow-list when a sandbox opens them as well.
    ServiceManager_.untrusted-open-check_ = :: | gid/int uuid/string |
      sandbox-may-use_ gid uuid

  /**
  Whether the sandboxed process group $gid may use the service with the
    given $uuid: the service is always available or on the allow-list of
    its container.
  */
  sandbox-may-use_ gid/int uuid/string -> bool:
    if ALWAYS-AVAILABLE.contains uuid: return true
    check := may-use-service
    return check != null and (check.call gid uuid) == true

  // Every process needs service discovery, sandboxed ones included.
  accepts-untrusted-clients -> bool:
    return true

  handle index/int arguments/any --gid/int --client/int -> any:
    pid := pid --client=client
    if index == ServiceDiscoveryService.DISCOVER-INDEX:
      // Older clients don't send the opt-in for providers in sandboxes.
      untrusted-providers := arguments.size > 2 and arguments[2] == true
      return discover arguments[0] --wait=arguments[1] client --pid=pid --gid=gid
          --untrusted-providers=untrusted-providers
    if index == ServiceDiscoveryService.WATCH-INDEX:
      return watch pid arguments
    if index == ServiceDiscoveryService.LISTEN-INDEX:
      return listen pid arguments --gid=gid
    if index == ServiceDiscoveryService.UNLISTEN-INDEX:
      return unlisten pid arguments
    unreachable

  listen pid/int arguments/List --gid/int -> none:
    id := arguments[0]
    uuid := arguments[1]
    service-name := arguments[2]
    service-priority := arguments[5]
    service-tags := arguments[6]
    // Older clients don't send the opt-in for sandboxed clients.
    accepts-untrusted := arguments.size > 7 ? arguments[7] : false
    // Clients look at every discovered entry, so an entry with a value of
    // the wrong type (for example a tag that isn't a string) would make
    // the discovery of the service fail for all of them.
    if id is not int or uuid is not string or service-name is not string
        or arguments[3] is not int or arguments[4] is not int
        or service-priority is not int
        or (service-tags != null and service-tags is not List)
        or accepts-untrusted is not bool:
      throw "WRONG_OBJECT_TYPE"
    if service-tags and (service-tags.any: it is not string): throw "WRONG_OBJECT_TYPE"

    untrusted := is-untrusted_ pid
    if untrusted:
      // Providing services is a privilege: a sandbox could otherwise offer
      // services that trusted clients expect from trusted providers.
      grant := may-provide-services
      if not (grant and (grant.call gid)): throw "SERVICE_REGISTRATION_DENIED"
      if uuid.size > MAX-UNTRUSTED-STRING-SIZE or service-name.size > MAX-UNTRUSTED-STRING-SIZE:
        throw "INVALID_ARGUMENT"
      if service-tags and (service-tags.size > MAX-UNTRUSTED-TAGS
          or (service-tags.any: it.size > MAX-UNTRUSTED-STRING-SIZE)):
        throw "INVALID_ARGUMENT"
      existing := services-by-pid_.get pid
      if existing and existing.size >= MAX-UNTRUSTED-SERVICES: throw "QUOTA_EXCEEDED"

    services := services-by-pid_.get pid --init=(: {:})
    if services.contains id: throw "Service id $id is already in use"

    if untrusted:
      // Sandboxed providers live in their own namespace: the tag puts them
      // there (see $is-visible_), so only trusted clients that opt in
      // discover them, and never instead of a trusted provider. Other
      // sandboxes don't discover them.
      service-priority = ServiceProvider.PRIORITY-UNPREFERRED-STRONGLY
      service-tags = service-tags ? (service-tags + [TAG-UNTRUSTED-PROVIDER]) : [TAG-UNTRUSTED-PROVIDER]
      accepts-untrusted = false
    service := DiscoverableService
        --pid=pid
        --id=id
        --uuid=uuid
        --name=service-name
        --major=arguments[3]
        --minor=arguments[4]
        --priority=service-priority
        --tags=service-tags
        --accepts-untrusted=accepts-untrusted
    services[id] = service

    // Register the service based on its uuid and sort the all services
    // with the same uuid by descending priority.
    uuids := services-by-uuid_.get uuid --init=(: [])
    uuids.add service
    uuids.sort --in-place: | a b | b.priority.compare-to a.priority

    // If anyone is waiting for this service, signal them.
    waiting_.get uuid --if-present=: | resources/List |
      resources.do: | resource/DiscoveryResource |
        if is-visible_ service --untrusted=resource.untrusted --untrusted-providers=resource.untrusted-providers --allowed=resource.allowed:
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

  discover uuid/string --wait/bool client/int --pid/int --gid/int --untrusted-providers/bool -> List:
    services/List? := null
    resource-serialized := null
    untrusted := is-untrusted_ pid
    // A sandbox only discovers the services its container may use.
    allowed := not untrusted or (sandbox-may-use_ gid uuid)
    if wait:
      if untrusted:
        if uuid.size > MAX-UNTRUSTED-STRING-SIZE: throw "INVALID_ARGUMENT"
        if (waiting-by-pid_.get pid --if-absent=: 0) >= MAX-UNTRUSTED-WAITING:
          throw "QUOTA_EXCEEDED"
      resource := DiscoveryResource uuid this client
          --pid=pid
          --untrusted=untrusted
          --untrusted-providers=untrusted-providers
          --allowed=allowed
      (waiting_.get uuid --init=: []).add resource
      resource-serialized = resource.serialize-for-rpc
    services = services-by-uuid_.get uuid
    if services:
      services = services.filter: | service/DiscoverableService |
        is-visible_ service --untrusted=untrusted --untrusted-providers=untrusted-providers --allowed=allowed
      if untrusted:
        // Discovery is how a sandboxed process gets the capability to send
        // messages to a provider: grant it for every discovered provider.
        services.do: | service/DiscoverableService |
          process-grant-send_ pid service.pid
      if services.is-empty: services = null
    return [array-of-services_ services, resource-serialized]

  /**
  Whether a client discovers the given $service.

  Providers tagged with $TAG-UNTRUSTED-PROVIDER (every provider in a
    sandbox) are only discovered by trusted clients that opt in to them
    ($untrusted-providers): plain selectors never get them, not even when
    no trusted provider of the service runs.

  Sandboxed ($untrusted) clients only discover providers that serve them
    (that accept sandboxed clients), and only if their container may use
    the service ($allowed, see $sandbox-may-use_). The providers in the
    system process are reachable without discovery; they check the same
    when a sandbox opens them (see $ServiceManager_.untrusted-open-check_).
    Other clients don't discover the system services that only exist for
    sandboxed clients.
  */
  static is-visible_ service/DiscoverableService --untrusted/bool --untrusted-providers/bool --allowed/bool -> bool:
    tags := service.tags
    if tags and tags.contains TAG-UNTRUSTED-PROVIDER:
      if untrusted or not untrusted-providers: return false
    in-system-process := service.pid == Process.current.id
    if untrusted: return allowed and service.accepts-untrusted
    return not (in-system-process and tags and tags.contains TAG-SANDBOX-ONLY)

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

  discover uuid/string --wait/bool --untrusted-providers/bool=false -> List:
    unreachable  // <-- TODO(kasper): nasty

  listen id/int uuid/string -> none
      --name/string
      --major/int
      --minor/int
      --priority/int
      --tags/List
      --accepts-untrusted/bool=false:
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
Checks the services list of a launch policy (see
  $ContainerService.POLICY-SERVICES-INDEX): $ContainerService.ALL-SERVICES
  or a list of at most
  $ContainerService.MAX-POLICY-SERVICES non-empty strings of at most
  $ContainerService.MAX-POLICY-SERVICE-SIZE bytes. The list is kept in the
  system process for as long as the container lives.
*/
validate-service-list_ services/any -> none:
  if services == ContainerService.ALL-SERVICES: return
  if services is not List: throw "WRONG_OBJECT_TYPE"
  if services.size > ContainerService.MAX-POLICY-SERVICES: throw "INVALID_ARGUMENT"
  services.do: | uuid |
    if uuid is not string: throw "WRONG_OBJECT_TYPE"
    if uuid.is-empty or uuid.size > ContainerService.MAX-POLICY-SERVICE-SIZE:
      throw "INVALID_ARGUMENT"

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
