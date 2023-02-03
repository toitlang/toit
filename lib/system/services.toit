// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for defining and using services.
*/

import rpc
import rpc.broker
import monitor

import system.api.service_discovery
  show
    ServiceDiscoveryService
    ServiceDiscoveryServiceClient

// RPC procedure numbers used for using services from clients.
RPC_SERVICES_OPEN_           /int ::= 300
RPC_SERVICES_CLOSE_          /int ::= 301
RPC_SERVICES_INVOKE_         /int ::= 302
RPC_SERVICES_CLOSE_RESOURCE_ /int ::= 303

// Internal limits.
RANDOM_ID_LIMIT_       /int ::= 0x3fff_ffff
RESOURCE_HANDLE_LIMIT_ /int ::= 0x1fff_ffff  // Will be shifted up by one.

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

  is_allowed_ --name/string --major/int --minor/int --tags/List? -> bool:
    return true

class ServiceSelectorRestricted extends ServiceSelector:
  tags_ := {:}    // Map<string, bool>
  names_ ::= {:}  // Map<string, List<ServiceSelectorRestriction_>>

  tags_include_allowed_/bool := false
  names_include_allowed_/bool := false

  constructor.internal_ selector/ServiceSelector:
    super --uuid=selector.uuid --major=selector.major --minor=selector.minor

  restrict -> ServiceSelectorRestricted:
    throw "Already restricted"

  allow --name/string --major/int?=null --minor/int?=null -> ServiceSelectorRestricted:
    return add_name_ --name=name --major=major --minor=minor --allow
  deny --name/string --major/int?=null --minor/int?=null -> ServiceSelectorRestricted:
    return add_name_ --name=name --major=major --minor=minor --no-allow

  allow --tag/string -> ServiceSelectorRestricted:
    return allow --tags=[tag]
  allow --tags/List -> ServiceSelectorRestricted:
    return add_tags_ --tags=tags --allow
  deny --tag/string -> ServiceSelectorRestricted:
    return deny --tags=[tag]
  deny --tags/List -> ServiceSelectorRestricted:
    return add_tags_ --tags=tags --no-allow

  add_name_ --name/string --major/int? --minor/int? --allow/bool -> ServiceSelectorRestricted:
    if minor and not major: throw "Must have major version to match on minor"
    restrictions := names_.get name --init=: []
    // Check that the new restriction doesn't conflict with an existing one.
    restrictions.do: | restriction/ServiceSelectorRestriction_ |
      match := true
      if major: match = (not restriction.major) or restriction.major == major
      if match and minor: match = (not restriction.minor) or restriction.minor == minor
      if match: throw "Cannot have multiple entries for the same named version"
    if allow: names_include_allowed_ = true
    restrictions.add (ServiceSelectorRestriction_ allow major minor)
    return this

  add_tags_ --tags/List --allow/bool -> ServiceSelectorRestricted:
    tags.do: | tag/string |
      if (tags_.get tag) == (not allow): throw "Cannot allow and deny the same tag"
      if allow: tags_include_allowed_ = true
      tags_[tag] = allow
    return this

  is_allowed_ --name/string --major/int --minor/int --tags/List? -> bool:
    // Check that the name and versions are allowed.
    restrictions := names_.get name
    name_allowed := not names_include_allowed_
    if restrictions: restrictions.do: | restriction/ServiceSelectorRestriction_? |
      match := (not restriction.major) or restriction.major == major
      if match: match = (not restriction.minor) or restriction.minor == minor
      if not match: continue.do
      if not restriction.allow: return false
      // We found named version that was explicitly allowed. Continue through
      // the restrictions so we can find any explicitly denied named versions.
      name_allowed = true
    if not name_allowed: return false

    // Check that the tag is allowed. If no tag is registered as allowed,
    // we allow all non-denied tags.
    tags_allowed := not tags_include_allowed_
    if tags: tags.do: | tag/string |
      tags_.get tag --if_present=: | allowed/bool |
        if not allowed: return false
        // We found a tag that was explicitly allowed. Continue through
        // the tags so we can find any explicitly denied tags.
        tags_allowed = true
    return tags_allowed

/**
Base class for clients that connect to and use provided services
  (see $ServiceProvider).

Typically, users call the $open method on a subclass of the client. This then
  discovers the corresponding provider and connects to it.

Subclasses implement service-specific methods to provide convenient APIs.
*/
class ServiceClient:
  // TODO(kasper): Make this non-nullable.
  selector/ServiceSelector?

  _id_/int? := null
  _pid_/int? := null

  _name_/string? := null
  _major_/int := 0
  _minor_/int := 0
  _patch_/int := 0
  _tags_/List? := null

  static DEFAULT_OPEN_TIMEOUT /Duration ::= Duration --ms=100

  // TODO(kasper): Deprecate this.
  _default_timeout_/Duration? ::= ?

  // TODO(kasper): Deprecate this constructor.
  constructor --open/bool=true:
    // If we're opening the client as part of constructing it, we instruct the
    // service discovery service to wait for the requested service to be provided.
    selector = null
    _default_timeout_ = open ? DEFAULT_OPEN_TIMEOUT : null
    if open and not this.open: throw "Cannot find service"

  // TODO(kasper): Deprecate this helper.
  open_ uuid/string major/int minor/int -> ServiceClient?
      --timeout/Duration?=_default_timeout_:
    assert: not this.selector
    return _open_ (ServiceSelector --uuid=uuid --major=major --minor=minor)
       --timeout=timeout

  constructor selector/ServiceSelector:
    // TODO(kasper): Simplify this once the we don't need the
    // legacy constructor.
    this.selector = selector
    _default_timeout_ = null

  open --timeout/Duration?=DEFAULT_OPEN_TIMEOUT -> ServiceClient:
    return open --timeout=timeout --if_absent=: throw "Cannot find service"

  open --timeout/Duration?=null [--if_absent] -> any:
    if not selector: throw "Must override open in client"
    assert: not this._default_timeout_
    if client := _open_ selector --timeout=timeout: return client
    return if_absent.call

  _open_ selector/ServiceSelector --timeout/Duration? -> ServiceClient?:
    discovered/List? := null
    if timeout:
      catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout timeout: discovered = _client_.discover selector.uuid --wait
    else:
      discovered = _client_.discover selector.uuid --no-wait
    if not discovered: return null

    candidate_index := null
    candidate_priority := null
    for i := 0; i < discovered.size; i += 7:
      tags := discovered[i + 6]
      allowed := selector.is_allowed_
          --name=discovered[i + 2]
          --major=discovered[i + 3]
          --minor=discovered[i + 4]
          --tags=tags
      if not allowed: continue
      priority := discovered[i + 5]
      if not candidate_index:
        candidate_index = i
        candidate_priority = priority
      else if priority < candidate_priority:
        // The remaining entries have lower priorities and
        // we already found a suitable candidate.
        break
      else:
        // Found multiple candidates with the same priority.
        throw "Cannot disambiguate"

    if not candidate_index: return null
    pid := discovered[candidate_index]
    id := discovered[candidate_index + 1]
    return _open_ selector --pid=pid --id=id

  _open_ selector/ServiceSelector --pid/int --id/int -> ServiceClient:
    if _id_: throw "Already opened"
    // Open the client by doing a RPC-call to the discovered process.
    // This returns the client id necessary for invoking service methods.
    definition ::= rpc.invoke pid RPC_SERVICES_OPEN_ [
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
    add_finalizer this:: close
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
    remove_finalizer this
    ServiceResourceProxyManager_.unregister_all id
    critical_do: rpc.invoke pid RPC_SERVICES_CLOSE_ id

  stringify -> string:
    return "service:$_name_@$(_major_).$(_minor_).$(_patch_)"

  invoke_ index/int arguments/any -> any:
    id := _id_
    if not id: throw "Client closed"
    return rpc.invoke _pid_ RPC_SERVICES_INVOKE_ [id, index, arguments]

  _close_resource_ handle/int -> none:
    // If this client is closed, we've already closed all its resources.
    id := _id_
    if not id: return
    // TODO(kasper): Should we avoid using the task deadline here
    // and use our own? If we're timing out and trying to call
    // close after timing out, it should still work.
    critical_do: rpc.invoke _pid_ RPC_SERVICES_CLOSE_RESOURCE_ [id, handle]

/**
A handler for requests from clients.

A $ServiceProvider may provide multiple services, each of which comes with a
  handler. That handler is then called for the corresponding request from the
  client.
*/
interface ServiceHandler:
  handle pid/int client/int index/int arguments/any-> any

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

  _services_/List ::= []
  _manager_/ServiceManager_? := null
  _ids_/List? := null

  _clients_/Set ::= {}  // Set<int>
  _clients_closed_/int := 0
  _clients_closed_signal_ ::= monitor.Signal

  _resources_/Map ::= {:}  // Map<int, Map<int, Object>>
  _resource_handle_next_/int := ?

  constructor .name --.major --.minor --.patch=0 --.tags=null:
    _resource_handle_next_ = random RESOURCE_HANDLE_LIMIT_

  on_opened client/int -> none:
    // Override in subclasses.

  on_closed client/int -> none:
    // Override in subclasses.

  stringify -> string:
    return "service:$name@$(major).$(minor).$(patch)"

  /**
  Registers a handler for the given $selector.

  This function should only be called from subclasses (typically in their constructor).
  */
  provides selector/ServiceSelector --handler/ServiceHandler -> none
      --id/int?=null
      --priority/int=100
      --tags/List?=null:
    provider_tags := this.tags
    if provider_tags: tags = tags ? (provider_tags + tags) : provider_tags
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
    _clients_closed_ = 0
    // TODO(kasper): Handle the case where one of the calls
    // to listen fails.
    _ids_ = Array_ _services_.size: _manager_.listen _services_[it] this

  uninstall --wait/bool=false -> none:
    if wait:
      _clients_closed_signal_.wait:
        _clients_closed_ > 0 and _clients_.is_empty
    if not _manager_: return
    _clients_.do: _manager_.close it
    if _manager_: _uninstall_

  resource client/int handle/int -> ServiceResource:
    return _find_resource_ client handle

  resources_do [block] -> none:
    _resources_.do: | client/int resources/Map |
      resources.do: | handle/int resource/ServiceResource |
        block.call resource client

  _open_ client/int -> List:
    _clients_.add client
    catch --trace: on_opened client
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
    _clients_closed_++
    _clients_closed_signal_.raise
    // Finally, let the service know that the client is now closed.
    catch --trace: on_closed client

  _register_resource_ client/int resource/ServiceResource notifiable/bool -> int:
    handle ::= _new_resource_handle_ notifiable
    resources ::= _resources_.get client --init=(: {:})
    resources[handle] = resource
    return handle

  _find_resource_ client/int handle/int -> ServiceResource?:
    resources ::= _resources_.get client --if_absent=(: return null)
    return resources.get handle

  _unregister_resource_ client/int handle/int -> none:
    resources ::= _resources_.get client
    if not resources: return
    result ::= resources.get handle
    if not result: return
    resources.remove handle
    if resources.is_empty: _resources_.remove client

  _new_resource_handle_ notifiable/bool -> int:
    handle ::= _resource_handle_next_
    next ::= handle + 1
    _resource_handle_next_ = (next >= RESOURCE_HANDLE_LIMIT_) ? 0 : next
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
    if not _resources_.is_empty: throw "Leaked $_resources_"
    // TODO(kasper): Handle the case where one of the calls
    // to unlisten fails.
    _ids_.do: _manager_.unlisten it
    _ids_ = null
    _manager_ = null

// TODO(kasper): Deprecate this.
abstract class ServiceDefinition extends ServiceProvider implements ServiceHandler:
  constructor name/string --major/int --minor/int --patch/int=0:
    super name --major=major --minor=minor --patch=patch

  abstract handle pid/int client/int index/int arguments/any -> any

  provides selector/ServiceSelector -> none:
    super selector --handler=this

  provides uuid/string major/int minor/int -> none:
    selector := ServiceSelector --uuid=uuid --major=major --minor=minor
    super selector --handler=this

abstract class ServiceResource implements rpc.RpcSerializable:
  _provider_/ServiceProvider? := ?
  _client_/int ::= ?
  _handle_/int? := null

  constructor ._provider_ ._client_ --notifiable/bool=false:
    _handle_ = _provider_._register_resource_ _client_ this notifiable

  abstract on_closed -> none

  is_closed -> bool:
    return _handle_ == null

  /**
  The $notify_ method is used for sending notifications to remote clients'
    resource proxies. The notifications are delivered asynchronously and
    the method returns immediately.
  */
  notify_ notification/any -> none:
    handle := _handle_
    if not handle: throw "ALREADY_CLOSED"
    if handle & 1 == 0: throw "Resource not notifiable"
    _provider_._manager_.notify _client_ handle notification

  close -> none:
    handle := _handle_
    if not handle: return
    provider := _provider_
    _handle_ = _provider_ = null
    provider._unregister_resource_ _client_ handle
    on_closed

  serialize_for_rpc -> int:
    return _handle_

abstract class ServiceResourceProxy:
  client_/ServiceClient ::= ?
  _handle_/int? := ?

  constructor .client_ ._handle_:
    add_finalizer this:: close
    if _handle_ & 1 == 1:
      ServiceResourceProxyManager_.instance.register client_.id _handle_ this

  is_closed -> bool:
    return _handle_ == null

  handle_ -> int:
    return _handle_

  /**
  The $on_notified_ method is called asynchronously when the remote resource
    has been notified through a call to $ServiceResource.notify_.
  */
  on_notified_ notification/any -> none:
    // Override in subclasses.

  close:
    handle := _handle_
    if not handle: return
    _handle_ = null
    remove_finalizer this
    if handle & 1 == 1:
      ServiceResourceProxyManager_.instance.unregister client_.id handle
    catch --trace: client_._close_resource_ handle

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
    set_system_message_handler_ SYSTEM_RPC_NOTIFY_RESOURCE_ this

  register client/int handle/int proxy/ServiceResourceProxy -> none:
    proxies := proxies_.get client --init=(: {:})
    proxies[handle] = proxy

  unregister client/int handle/int -> none:
    proxies := proxies_.get client
    if not proxies: return
    proxies.remove handle
    if proxies.is_empty: proxies_.remove client

  // This method is static to avoid creating an instance of the
  // proxy manager when it isn't needed.
  static unregister_all client/int -> none:
    proxies := proxies_
    if not proxies: return
    proxies.remove client

  on_message type/int gid/int pid/int message/any -> none:
    assert: type == SYSTEM_RPC_NOTIFY_RESOURCE_
    client ::= message[0]
    handle ::= message[1]
    proxies ::= proxies_.get client
    if not proxies: return
    proxy ::= proxies.get handle
    if proxy: proxy.on_notified_ message[2]

class ServiceManager_ implements SystemMessageHandler_:
  static instance := ServiceManager_
  static uninitialized/bool := true

  broker_/broker.RpcBroker ::= broker.RpcBroker

  clients_/Map ::= {:}              // Map<int, int>
  clients_by_pid_/Map ::= {:}       // Map<int, Set<int>>

  providers_/Map ::= {:}            // Map<int, ServiceProvider>
  providers_by_client_/Map ::= {:}  // Map<int, ServiceProvider>
  handlers_by_client_/Map ::= {:}   // Map<int, ServiceHandler>

  constructor:
    set_system_message_handler_ SYSTEM_RPC_NOTIFY_TERMINATED_ this
    broker_.register_procedure RPC_SERVICES_OPEN_:: | arguments _ pid |
      open pid arguments[0] arguments[1] arguments[2] arguments[3]
    broker_.register_procedure RPC_SERVICES_CLOSE_:: | arguments |
      close arguments
    broker_.register_procedure RPC_SERVICES_INVOKE_:: | arguments _ pid |
      client/int ::= arguments[0]
      handler/ServiceHandler ::= handlers_by_client_[client]
      handler.handle pid client arguments[1] arguments[2]
    broker_.register_procedure RPC_SERVICES_CLOSE_RESOURCE_:: | arguments |
      client/int ::= arguments[0]
      providers_by_client_.get client --if_present=: | provider/ServiceProvider |
        resource/ServiceResource? := provider._find_resource_ client arguments[1]
        if resource: resource.close
    broker_.install
    uninitialized = false

  static is_empty -> bool:
    return uninitialized or instance.providers_.is_empty

  listen service/Service_ provider/ServiceProvider -> int:
    id := assign_id_ service.id providers_ provider
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

    clients/Set ::= clients_by_pid_.get pid --init=(: {})
    if clients.is_empty and pid != Process.current.id:
      // From this point forward, we need to be told if the client
      // process goes away so we can clean up.
      _client_.watch pid

    client ::= assign_id_ null clients_ pid
    clients.add client
    providers_by_client_[client] = provider
    handlers_by_client_[client] = service.handler
    return provider._open_ client

  notify client/int handle/int notification/any -> none:
    pid/int? := clients_.get client
    if not pid: return  // Already closed.
    process_send_ pid SYSTEM_RPC_NOTIFY_RESOURCE_ [client, handle, notification]
    if not is_processing_messages_: yield  // Yield to allow intra-process messages to be processed.

  close client/int -> none:
    pid/int? := clients_.get client
    if not pid: return  // Already closed.
    clients_.remove client
    // Unregister the client in the client sets.
    provider/ServiceProvider := providers_by_client_[client]
    providers_by_client_.remove client
    handlers_by_client_.remove client
    // Only unregister the client from the clients set
    // for the pid if we haven't already done so as part
    // of a call to $close_all.
    clients/Set? ::= clients_by_pid_.get pid
    if clients:
      clients.remove client
      if clients.is_empty: clients_by_pid_.remove pid
    provider._close_ client

  close_all pid/int -> none:
    clients/Set? ::= clients_by_pid_.get pid
    if not clients: return
    // We avoid manipulating the clients set in the $close
    // method by taking ownership of it here.
    clients_by_pid_.remove pid
    clients.do: close it

  on_message type/int gid/int pid/int message/any -> none:
    assert: type == SYSTEM_RPC_NOTIFY_TERMINATED_
    // The other process isn't necessarily the sender of the
    // notifications. They almost always come from the system
    // process and are sent as part of the discovery handshake.
    other/int ::= message
    broker_.cancel_requests other
    close_all other

  assign_id_ id/int? map/Map value/any -> int:
    if not id:
      id = random_id_ map
    else if map.contains id:
      throw "Already registered"
    map[id] = value
    return id

  random_id_ map/Map -> int:
    while true:
      guess := random RANDOM_ID_LIMIT_
      if not map.contains guess: return guess
