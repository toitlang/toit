// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for defining and using services.
*/

import rpc
import rpc.broker
import monitor

import system.api.service-discovery
  show
    ServiceDiscoveryService
    ServiceDiscoveryServiceClient

// RPC procedure numbers used for using services from clients.
RPC-SERVICES-OPEN_           /int ::= 300
RPC-SERVICES-CLOSE_          /int ::= 301
RPC-SERVICES-INVOKE_         /int ::= 302
RPC-SERVICES-CLOSE-RESOURCE_ /int ::= 303

// Internal limits.
RANDOM-ID-LIMIT_       /int ::= 0x3fff_ffff
RESOURCE-HANDLE-LIMIT_ /int ::= 0x1fff_ffff  // Will be shifted up by one.

_client_ /ServiceDiscoveryService ::= (ServiceDiscoveryServiceClient).open

/**
A service selector is used to identify and discover services. It
  has a unique id that never changes and major and minor versions
  numbers that support evolving APIs over time.

On the $ServiceProvider side, the selector is used when providing
  a service so that clients can discover it later.

On the $ServiceClient side, the selector is used when discovering
  services, and in this context it can also be restricted to help
  disambiguate between multiple variants of a service provided
  by multiple providers.
*/
class ServiceSelector:
  uuid/string
  major/int
  minor/int
  constructor --.uuid --.major --.minor:

  /**
  Returns a restricted variant of this $ServiceSelector that can
    be used in the service discovery process to allow and deny
    discovered services.
  */
  restrict -> ServiceSelectorRestricted:
    return ServiceSelectorRestricted.internal_ this

  /**
  Whether this $ServiceSelector matches $selector and thus
    identifies the same version of a specific service API.
  */
  matches selector/ServiceSelector -> bool:
    return uuid == selector.uuid and
        major == selector.major and
        minor == selector.minor

  is-allowed_ --name/string --major/int --minor/int --tags/List? -> bool:
    return true

class ServiceSelectorRestricted extends ServiceSelector:
  tags_ := {:}    // Map<string, bool>
  names_ ::= {:}  // Map<string, List<ServiceSelectorRestriction_>>

  tags-include-allowed_/bool := false
  names-include-allowed_/bool := false

  constructor.internal_ selector/ServiceSelector:
    super --uuid=selector.uuid --major=selector.major --minor=selector.minor

  restrict -> ServiceSelectorRestricted:
    throw "Already restricted"

  allow --name/string --major/int?=null --minor/int?=null -> ServiceSelectorRestricted:
    return add-name_ --name=name --major=major --minor=minor --allow
  deny --name/string --major/int?=null --minor/int?=null -> ServiceSelectorRestricted:
    return add-name_ --name=name --major=major --minor=minor --no-allow

  allow --tag/string -> ServiceSelectorRestricted:
    return allow --tags=[tag]
  allow --tags/List -> ServiceSelectorRestricted:
    return add-tags_ --tags=tags --allow
  deny --tag/string -> ServiceSelectorRestricted:
    return deny --tags=[tag]
  deny --tags/List -> ServiceSelectorRestricted:
    return add-tags_ --tags=tags --no-allow

  add-name_ --name/string --major/int? --minor/int? --allow/bool -> ServiceSelectorRestricted:
    if minor and not major: throw "Must have major version to match on minor"
    restrictions := names_.get name --init=: []
    // Check that the new restriction doesn't conflict with an existing one.
    restrictions.do: | restriction/ServiceSelectorRestriction_ |
      match := true
      if major: match = (not restriction.major) or restriction.major == major
      if match and minor: match = (not restriction.minor) or restriction.minor == minor
      if match: throw "Cannot have multiple entries for the same named version"
    if allow: names-include-allowed_ = true
    restrictions.add (ServiceSelectorRestriction_ allow major minor)
    return this

  add-tags_ --tags/List --allow/bool -> ServiceSelectorRestricted:
    tags.do: | tag/string |
      if (tags_.get tag) == (not allow): throw "Cannot allow and deny the same tag"
      if allow: tags-include-allowed_ = true
      tags_[tag] = allow
    return this

  is-allowed_ --name/string --major/int --minor/int --tags/List? -> bool:
    // Check that the name and versions are allowed.
    restrictions := names_.get name
    name-allowed := not names-include-allowed_
    if restrictions: restrictions.do: | restriction/ServiceSelectorRestriction_? |
      match := (not restriction.major) or restriction.major == major
      if match: match = (not restriction.minor) or restriction.minor == minor
      if not match: continue.do
      if not restriction.allow: return false
      // We found named version that was explicitly allowed. Continue through
      // the restrictions so we can find any explicitly denied named versions.
      name-allowed = true
    if not name-allowed: return false

    // Check that the tag is allowed. If no tag is registered as allowed,
    // we allow all non-denied tags.
    tags-allowed := not tags-include-allowed_
    if tags: tags.do: | tag/string |
      tags_.get tag --if-present=: | allowed/bool |
        if not allowed: return false
        // We found a tag that was explicitly allowed. Continue through
        // the tags so we can find any explicitly denied tags.
        tags-allowed = true
    return tags-allowed

class DiscoveryProxy_ extends ServiceResourceProxy:
  channel_/monitor.Channel

  constructor client/ServiceClient .channel_ handle/int:
    super client handle

  on-notified_ notification/any -> none:
    channel_.send notification

/**
Base class for clients that connect to and use provided services
  (see $ServiceProvider).

Typically, users call the $open method on a subclass of the client. This then
  discovers the corresponding provider and connects to it.

Subclasses implement service-specific methods to provide convenient APIs.
*/
class ServiceClient:
  selector/ServiceSelector

  _id_/int? := null
  _pid_/int? := null

  _name_/string? := null
  _major_/int := 0
  _minor_/int := 0
  _patch_/int := 0
  _tags_/List? := null

  static DEFAULT-OPEN-TIMEOUT /Duration ::= Duration --ms=100

  constructor .selector:

  open --timeout/Duration? -> ServiceClient:
    return open --timeout=timeout --if-absent=: throw "Cannot find service"

  open -> ServiceClient:
    return open --timeout=DEFAULT-OPEN-TIMEOUT --if-absent=: throw "Cannot find service"

  open --timeout/Duration?=null [--if-absent] -> any:
    discovered/List? := null
    proxy/DiscoveryProxy_? := null
    channel/monitor.Channel? := null
    if timeout:
      // Get a pair with a list of current services, and a resource that will
      // notify us of new services as they are registered.
      result := _client_.discover selector.uuid --wait
      if result:
        discovered = result[0]
        resource := result[1]
        channel = monitor.Channel 1
        proxy = DiscoveryProxy_ (_client_ as ServiceDiscoveryServiceClient) channel resource
    else:
      // Get a list of current services, but don't wait for new ones.
      result := _client_.discover selector.uuid --no-wait
      if result: discovered = result[0]

    try:
      if discovered:
        result := find-service_ discovered
        if result: return result

      if timeout:
        // We got back a proxy for a resource, which will notify us when the
        // service we want has started up.
        catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
          with-timeout timeout:
            while true:
              discovered = channel.receive
              result := find-service_ discovered
              if result: return result
      return if-absent.call
    finally:
      if proxy: proxy.close
    unreachable

  find-service_ discovered/List -> ServiceClient?:
    candidate-index := null
    candidate-priority := null
    for i := 0; i < discovered.size; i += 7:
      tags := discovered[i + 6]
      allowed := selector.is-allowed_
          --name=discovered[i + 2]
          --major=discovered[i + 3]
          --minor=discovered[i + 4]
          --tags=tags
      if not allowed: continue
      priority := discovered[i + 5]
      if not candidate-index:
        candidate-index = i
        candidate-priority = priority
      else if priority < candidate-priority:
        // The remaining entries have lower priorities and
        // we already found a suitable candidate.
        break
      else:
        // Found multiple candidates with the same priority.
        throw "Cannot disambiguate"

    if not candidate-index: return null

    pid := discovered[candidate-index]
    id := discovered[candidate-index + 1]
    return _open_ selector --pid=pid --id=id

  _open_ selector/ServiceSelector --pid/int --id/int -> ServiceClient:
    if _id_: throw "Already opened"
    // Open the client by doing a RPC-call to the discovered process.
    // This returns the client id necessary for invoking service methods.
    definition ::= rpc.invoke pid RPC-SERVICES-OPEN_ [
      id, selector.uuid, selector.major, selector.minor
    ]
    _pid_ = pid
    _id_ = definition[0]
    _name_ = definition[1]
    _major_ = definition[2]
    _minor_ = definition[3]
    _patch_ = definition[4]
    _tags_ = definition[5]
    // Close the client if the reference goes away, so the service
    // process can clean things up.
    add-finalizer this:: close
    return this

  id -> int?:
    return _id_

  name -> string:
    return _name_

  major -> int:
    return _major_

  minor -> int:
    return _minor_

  patch -> int:
    return _patch_

  close -> none:
    id := _id_
    if not id: return
    pid := _pid_
    _id_ = _name_ = _pid_ = null
    remove-finalizer this
    ServiceResourceProxyManager_.unregister-all id
    critical-do: rpc.invoke pid RPC-SERVICES-CLOSE_ id

  stringify -> string:
    return "service:$_name_@$(_major_).$(_minor_).$(_patch_)"

  invoke_ index/int arguments/any -> any:
    id := _id_
    if not id: throw "Client closed"
    return rpc.invoke _pid_ RPC-SERVICES-INVOKE_ [id, index, arguments]

  _close-resource_ handle/int -> none:
    // If this client is closed, we've already closed all its resources.
    id := _id_
    if not id: return
    // TODO(kasper): Should we avoid using the task deadline here
    // and use our own? If we're timing out and trying to call
    // close after timing out, it should still work.
    critical-do: rpc.invoke _pid_ RPC-SERVICES-CLOSE-RESOURCE_ [id, handle]

/**
A handler for requests from clients.

A $ServiceProvider may provide multiple services, each of which comes with a
  handler. That handler is then called for the corresponding request from the
  client.
*/
interface ServiceHandler:
  handle index/int arguments/any --gid/int --client/int -> any

/**
A service provider.

Service providers are classes that expose APIs through remote
  procedure calls (RPCs).

# Inheritance
Typically, subclasses implement the $ServiceHandler interface, and
  call the $provides method in their constructor, using 'this' as handler.

If the subclass implements multiple independent service APIs, it is
  useful to split the handling out into multiple implementations of
  $ServiceHandler to avoid running into issues with overlapping
  method indexes.
*/
class ServiceProvider:
  name/string
  major/int
  minor/int
  patch/int
  tags/List?

  static PRIORITY-UNPREFERRED-STRONGLY /int ::= 0x10
  static PRIORITY-UNPREFERRED          /int ::= 0x30
  static PRIORITY-UNPREFERRED-WEAKLY   /int ::= 0x50
  static PRIORITY-NORMAL               /int ::= 0x80
  static PRIORITY-PREFERRED-WEAKLY     /int ::= 0xb0
  static PRIORITY-PREFERRED            /int ::= 0xd0
  static PRIORITY-PREFERRED-STRONGLY   /int ::= 0xf0

  _services_/List ::= []
  _manager_/ServiceManager_? := null
  _ids_/List? := null

  _clients_/Set ::= {}  // Set<int>
  _clients-closed_/int := 0
  _clients-closed-signal_ ::= monitor.Signal

  _resources_/Map ::= {:}  // Map<int, Map<int, Object>>
  _resource-handle-next_/int := ?

  constructor .name --.major --.minor --.patch=0 --.tags=null:
    _resource-handle-next_ = random RESOURCE-HANDLE-LIMIT_

  on-opened client/int -> none:
    // Override in subclasses.

  on-closed client/int -> none:
    // Override in subclasses.

  stringify -> string:
    return "service:$name@$(major).$(minor).$(patch)"

  /**
  Registers a handler for the given $selector.

  This function should only be called from subclasses (typically in their constructor).
  */
  provides selector/ServiceSelector --handler/ServiceHandler -> none
      --id/int?=null
      --priority/int=PRIORITY-NORMAL
      --tags/List?=null:
    provider-tags := this.tags
    if provider-tags: tags = tags ? (provider-tags + tags) : provider-tags
    service := Service_
        --selector=selector
        --handler=handler
        --id=id
        --priority=priority
        --tags=tags
    _services_.add service

  install -> none:
    if _manager_: throw "Already installed"
    _manager_ = ServiceManager_.instance
    _clients-closed_ = 0
    // TODO(kasper): Handle the case where one of the calls
    // to listen fails.
    _ids_ = Array_ _services_.size: _manager_.listen _services_[it] this

  uninstall --wait/bool=false -> none:
    if wait:
      _clients-closed-signal_.wait:
        _clients-closed_ > 0 and _clients_.is-empty
    if not _manager_: return
    _clients_.do: _manager_.close it
    if _manager_: _uninstall_

  pid --client/int -> int?:
    if not _manager_: return null
    return _manager_.clients_.get client

  resource client/int handle/int -> ServiceResource:
    return _find-resource_ client handle

  resources-do [block] -> none:
    // Collect the resources into an array, so we can
    // deal nicely with modifications to the resource
    // set that occur while we iterate over it.
    size := 0
    _resources_.do: | _ map/Map | size += map.size
    resources := Array_ size
    index := 0
    _resources_.do: | _ map/Map |
      map.do: | _ resource |
        resources[index++] = resource
    // Call the block on each of the resources. The
    // resource passed to the block can have been
    // closed already, so it is up to the callee to
    // handle that correctly.
    resources.do block

  _open_ client/int -> List:
    _clients_.add client
    catch --trace: on-opened client
    return [ client, name, major, minor, patch, tags ]

  _close_ client/int -> none:
    resources ::= _resources_.get client
    if resources:
      // Iterate over a copy of the values, so we can remove
      // entries from the map when closing resources.
      resources.values.do: | resource/ServiceResource |
        catch --trace: resource.close
    // Unregister the client and notify all waiters that we've
    // closed a client. This unblocks any tasks waiting to uninstall
    // this service.
    _clients_.remove client
    _clients-closed_++
    _clients-closed-signal_.raise
    // Finally, let the service know that the client is now closed.
    catch --trace: on-closed client

  _register-resource_ client/int resource/ServiceResource notifiable/bool -> int:
    handle ::= _new-resource-handle_ notifiable
    resources ::= _resources_.get client --init=(: {:})
    resources[handle] = resource
    return handle

  _find-resource_ client/int handle/int -> ServiceResource?:
    resources ::= _resources_.get client --if-absent=(: return null)
    return resources.get handle

  _unregister-resource_ client/int handle/int -> none:
    resources ::= _resources_.get client
    if not resources: return
    result ::= resources.get handle
    if not result: return
    resources.remove handle
    if resources.is-empty: _resources_.remove client

  _new-resource-handle_ notifiable/bool -> int:
    handle ::= _resource-handle-next_
    next ::= handle + 1
    _resource-handle-next_ = (next >= RESOURCE-HANDLE-LIMIT_) ? 0 : next
    return (handle << 1) + (notifiable ? 1 : 0)

  _validate_ uuid/string major/int minor/int -> Service_:
    service/Service_? := _lookup_ uuid
    if not service: throw "$this does not provide service:$uuid"
    if major != service.selector.major:
      throw "$this does not provide service:$uuid@$(major).x"
    if minor > service.selector.minor:
      throw "$this does not provide service:$uuid@$(major).$(minor).x"
    return service

  _lookup_ uuid/string -> Service_?:
    _services_.do: | service/Service_ |
      if service.selector.uuid == uuid: return service
    return null

  _uninstall_ -> none:
    if not _resources_.is-empty: throw "Leaked $_resources_"
    // TODO(kasper): Handle the case where one of the calls
    // to unlisten fails.
    _ids_.do: _manager_.unlisten it
    _ids_ = null
    _manager_ = null

abstract class ServiceResource implements rpc.RpcSerializable:
  _provider_/ServiceProvider? := ?
  _client_/int ::= ?
  _handle_/int? := null

  constructor ._provider_ ._client_ --notifiable/bool=false:
    _handle_ = _provider_._register-resource_ _client_ this notifiable

  abstract on-closed -> none

  is-closed -> bool:
    return _handle_ == null

  /**
  The $notify_ method is used for sending notifications to remote clients'
    resource proxies. The notifications are delivered asynchronously and
    the method returns immediately.

  If $close is true, the resource is automatically closed before
    sending the notification.
  */
  notify_ notification/any --close/bool=false -> none:
    handle := _handle_
    if not handle: throw "ALREADY_CLOSED"
    if handle & 1 == 0: throw "Resource not notifiable"
    // Closing this resource clears the provider, so grab hold of
    // the provider before potentially closing the resource.
    provider := _provider_
    if close: catch --trace: this.close
    provider._manager_.notify _client_ handle notification

  close -> none:
    handle := _handle_
    if not handle: return
    provider := _provider_
    _handle_ = _provider_ = null
    provider._unregister-resource_ _client_ handle
    on-closed

  serialize-for-rpc -> int:
    return _handle_

abstract class ServiceResourceProxy:
  client_/ServiceClient ::= ?
  _handle_/int? := ?

  constructor .client_ ._handle_:
    add-finalizer this:: close
    if _handle_ & 1 == 1:
      ServiceResourceProxyManager_.instance.register client_.id _handle_ this

  is-closed -> bool:
    return _handle_ == null

  handle_ -> int:
    return _handle_

  /**
  The $on-notified_ method is called asynchronously when the remote resource
    has been notified through a call to $ServiceResource.notify_.
  */
  on-notified_ notification/any -> none:
    // Override in subclasses.

  close -> none:
    handle/int? := close-handle_
    if handle: catch --trace: client_._close-resource_ handle

  close-handle_ -> int?:
    handle := _handle_
    if not handle: return null
    _handle_ = null
    remove-finalizer this
    if handle & 1 == 1:
      ServiceResourceProxyManager_.instance.unregister client_.id handle
    return handle

class Service_:
  selector/ServiceSelector
  handler/ServiceHandler
  id/int?
  priority/int
  tags/List?
  constructor --.selector --.handler --.id --.priority --.tags:

class ServiceSelectorRestriction_:
  allow/bool
  major/int?
  minor/int?
  constructor .allow .major .minor:

class ServiceResourceProxyManager_ implements SystemMessageHandler_:
  static instance ::= ServiceResourceProxyManager_
  static proxies_/Map? := null

  constructor:
    proxies_ = {:}
    set-system-message-handler_ SYSTEM-RPC-NOTIFY-RESOURCE_ this

  register client/int handle/int proxy/ServiceResourceProxy -> none:
    proxies := proxies_.get client --init=(: Map.weak)
    proxies[handle] = proxy

  unregister client/int handle/int -> none:
    proxies := proxies_.get client
    if not proxies: return
    proxies.remove handle
    if proxies.is-empty: proxies_.remove client

  // This method is static to avoid creating an instance of the
  // proxy manager when it isn't needed.
  static unregister-all client/int -> none:
    proxies := proxies_
    if not proxies: return
    proxies.remove client

  on-message type/int gid/int pid/int message/any -> none:
    assert: type == SYSTEM-RPC-NOTIFY-RESOURCE_
    client ::= message[0]
    handle ::= message[1]
    proxies ::= proxies_.get client
    if not proxies: return
    proxy ::= proxies.get handle
    if proxy: proxy.on-notified_ message[2]

class ServiceManager_ implements SystemMessageHandler_:
  static instance := ServiceManager_
  static uninitialized/bool := true

  broker_/broker.RpcBroker ::= broker.RpcBroker

  clients_/Map ::= {:}              // Map<int, int>
  clients-by-pid_/Map ::= {:}       // Map<int, Set<int>>

  providers_/Map ::= {:}            // Map<int, ServiceProvider>
  providers-by-client_/Map ::= {:}  // Map<int, ServiceProvider>
  handlers-by-client_/Map ::= {:}   // Map<int, ServiceHandler>

  constructor:
    set-system-message-handler_ SYSTEM-RPC-NOTIFY-TERMINATED_ this
    broker_.register-procedure RPC-SERVICES-OPEN_:: | arguments _ pid |
      open pid arguments[0] arguments[1] arguments[2] arguments[3]
    broker_.register-procedure RPC-SERVICES-CLOSE_:: | arguments |
      close arguments
    broker_.register-procedure RPC-SERVICES-INVOKE_:: | arguments gid pid |
      client/int ::= arguments[0]
      handler/ServiceHandler ::= handlers-by-client_.get client --if-absent=(: throw "HANDLER_NOT_FOUND")
      handler.handle arguments[1] arguments[2] --gid=gid --client=client
    broker_.register-procedure RPC-SERVICES-CLOSE-RESOURCE_:: | arguments |
      client/int ::= arguments[0]
      providers-by-client_.get client --if-present=: | provider/ServiceProvider |
        resource/ServiceResource? := provider._find-resource_ client arguments[1]
        if resource: resource.close
    broker_.install
    uninitialized = false

  static is-empty -> bool:
    return uninitialized or instance.providers_.is-empty

  listen service/Service_ provider/ServiceProvider -> int:
    id := assign-id_ service.id providers_ provider
    // TODO(kasper): Clean up in the services
    // table if listen fails?
    _client_.listen id service.selector.uuid
        --name=provider.name
        --major=provider.major
        --minor=provider.minor
        --priority=service.priority
        --tags=service.tags
    return id

  unlisten id/int -> none:
    _client_.unlisten id
    providers_.remove id

  open pid/int id/int uuid/string major/int minor/int -> List:
    provider/ServiceProvider? ::= providers_.get id
    if not provider: throw "Unknown service:$id"
    service := provider._validate_ uuid major minor

    clients/Set ::= clients-by-pid_.get pid --init=(: {})
    if clients.is-empty and pid != Process.current.id:
      // From this point forward, we need to be told if the client
      // process goes away so we can clean up.
      _client_.watch pid

    client ::= assign-id_ null clients_ pid
    clients.add client
    providers-by-client_[client] = provider
    handlers-by-client_[client] = service.handler
    return provider._open_ client

  notify client/int handle/int notification/any -> none:
    pid/int? := clients_.get client
    if not pid: return  // Already closed.
    process-send_ pid SYSTEM-RPC-NOTIFY-RESOURCE_ [client, handle, notification]
    if Task_.current.critical-count_ == 0: yield

  close client/int -> none:
    pid/int? := clients_.get client
    if not pid: return  // Already closed.
    clients_.remove client
    // Unregister the client in the client sets.
    provider/ServiceProvider := providers-by-client_[client]
    providers-by-client_.remove client
    handlers-by-client_.remove client
    // Only unregister the client from the clients set
    // for the pid if we haven't already done so as part
    // of a call to $close-all.
    clients/Set? ::= clients-by-pid_.get pid
    if clients:
      clients.remove client
      if clients.is-empty: clients-by-pid_.remove pid
    provider._close_ client

  close-all pid/int -> none:
    clients/Set? ::= clients-by-pid_.get pid
    if not clients: return
    // We avoid manipulating the clients set in the $close
    // method by taking ownership of it here.
    clients-by-pid_.remove pid
    clients.do: close it

  on-message type/int gid/int pid/int message/any -> none:
    assert: type == SYSTEM-RPC-NOTIFY-TERMINATED_
    // The other process isn't necessarily the sender of the
    // notifications. They almost always come from the system
    // process and are sent as part of the discovery handshake.
    other/int ::= message
    broker_.cancel-requests other
    close-all other

  assign-id_ id/int? map/Map value/any -> int:
    if not id:
      id = random-id_ map
    else if map.contains id:
      throw "Already registered"
    map[id] = value
    return id

  random-id_ map/Map -> int:
    while true:
      guess := random RANDOM-ID-LIMIT_
      if not map.contains guess: return guess
