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

_client_ /ServiceDiscoveryService ::= ServiceDiscoveryServiceClient

abstract class ServiceClient:
  _id_/int? := null
  _pid_/int? := null

  _name_/string? := null
  _major_/int := 0
  _minor_/int := 0
  _patch_/int := 0

  _default_timeout_/Duration? ::= ?

  static DEFAULT_OPEN_TIMEOUT /Duration ::= Duration --ms=100

  constructor --open/bool=true:
    // If we're opening the client as part of constructing it, we instruct the
    // service discovery service to wait for the requested service to be provided.
    _default_timeout_ = open ? DEFAULT_OPEN_TIMEOUT : null
    if open and not this.open: throw "Cannot find service"

  abstract open -> ServiceClient?

  open_ uuid/string major/int minor/int -> ServiceClient?
      --pid/int?=null
      --timeout/Duration?=_default_timeout_:
    if _id_: throw "Already opened"

    id := 0  // TODO(kasper): Clean this up a bit.
    if not pid:
      discovered/List? := null
      if timeout:
        catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout timeout: discovered = _client_.discover uuid true
      else:
        discovered = _client_.discover uuid false
      if not discovered: return null

      pid = discovered[0]
      id = discovered[1]
      priority := discovered[2]

      if discovered.size > 3 and priority <= discovered[5]:
        throw "Cannot disambiguate"

    // Open the client by doing a RPC-call to the discovered process.
    // This returns the client id necessary for invoking service methods.
    definition ::= rpc.invoke pid RPC_SERVICES_OPEN_ [id, uuid, major, minor]
    _pid_ = pid
    _id_ = definition[0]
    _name_ = definition[1]
    _major_ = definition[2]
    _minor_ = definition[3]
    _patch_ = definition[4]
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

interface ServiceHandler:
  handle pid/int client/int index/int arguments/any-> any

abstract class ServiceProvider:
  name/string
  major/int
  minor/int
  patch/int

  _services_/List ::= []
  _manager_/ServiceManager_? := null
  _ids_/List? := null

  _clients_/Set ::= {}  // Set<int>
  _clients_closed_/int := 0
  _clients_closed_signal_ ::= monitor.Signal

  _resources_/Map ::= {:}  // Map<int, Map<int, Object>>
  _resource_handle_next_/int := ?

  constructor .name --.major/int --.minor/int --.patch/int=0:
    _resource_handle_next_ = random RESOURCE_HANDLE_LIMIT_

  on_opened client/int -> none:
    // Override in subclasses.

  on_closed client/int -> none:
    // Override in subclasses.

  stringify -> string:
    return "service:$name@$(major).$(minor).$(patch)"

  provides uuid/string major/int minor/int -> none
      --handler/ServiceHandler
      --id/int?=null
      --priority/int=100:
    service := Service_
        --uuid=uuid
        --major=major
        --minor=minor
        --handler=handler
        --id=id
        --priority=priority
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
    return [ client, name, major, minor, patch ]

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
    if major != service.major:
      throw "$this does not provide service:$uuid@$(major).x"
    if minor > service.minor:
      throw "$this does not provide service:$uuid@$(major).$(minor).x"
    return service

  _lookup_ uuid/string -> Service_?:
    _services_.do: if it.uuid == uuid: return it
    return null

  _uninstall_ -> none:
    if not _resources_.is_empty: throw "Leaked $_resources_"
    // TODO(kasper): Handle the case where one of the calls
    // to unlisten fails.
    _ids_.do: _manager_.unlisten it
    _ids_ = null
    _manager_ = null

// TODO(kasper): Document this a bit.
abstract class ServiceDefinition extends ServiceProvider implements ServiceHandler:
  constructor name/string --major/int --minor/int --patch/int=0:
    super name --major=major --minor=minor --patch=patch

  abstract handle pid/int client/int index/int arguments/any-> any

  provides uuid/string major/int minor/int:
    super uuid major minor --handler=this

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
  uuid/string
  major/int
  minor/int

  handler/ServiceHandler
  id/int?
  priority/int

  constructor --.uuid --.major --.minor --.handler --.id --.priority:
    // Do nothing.

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
    _client_.listen id service.uuid service.priority
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
