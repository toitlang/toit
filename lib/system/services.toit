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

// Notification kinds.
SERVICES_MANAGER_NOTIFY_ADD_PROCESS    /int ::= 0
SERVICES_MANAGER_NOTIFY_REMOVE_PROCESS /int ::= 1

// RPC procedure numbers used for using services from clients.
RPC_SERVICES_OPEN_           /int ::= 300
RPC_SERVICES_CLOSE_          /int ::= 301
RPC_SERVICES_INVOKE_         /int ::= 302
RPC_SERVICES_CLOSE_RESOURCE_ /int ::= 303

// Internal limits.
CLIENT_ID_LIMIT_       /int ::= 0x3fff_ffff
RESOURCE_HANDLE_LIMIT_ /int ::= 0x1fff_ffff  // Will be shifted up by one.

_client_ /ServiceDiscoveryService ::= ServiceDiscoveryServiceClient

abstract class ServiceClient:
  _id_/int? := null
  _pid_/int? := null

  _name_/string? := null
  _version_/List? := null
  _default_timeout_/int? ::= ?

  static DEFAULT_OPEN_TIMEOUT_MS /int ::= 100

  constructor --open/bool=true:
    // If we're opening the client as part of constructing it, we instruct the
    // service discovery service to wait for the requested service to be provided.
    _default_timeout_ = open ? DEFAULT_OPEN_TIMEOUT_MS : null
    if open and not this.open: throw "Cannot find service"

  abstract open -> ServiceClient?

  open_ uuid/string major/int minor/int -> ServiceClient?
      --pid/int?=null
      --timeout/int?=_default_timeout_:
    if _id_: throw "Already opened"
    if pid:
      process_send_ pid SYSTEM_RPC_NOTIFY_ [SERVICES_MANAGER_NOTIFY_ADD_PROCESS, current_process_]
    else:
      if timeout:
        catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout --ms=timeout: pid = _client_.discover uuid true
      else:
        pid = _client_.discover uuid false
      if not pid: return null
    // Open the client by doing a RPC-call to the discovered process.
    // This returns the client id necessary for invoking service methods.
    definition ::= rpc.invoke pid RPC_SERVICES_OPEN_ [uuid, major, minor]
    _pid_ = pid
    _id_ = definition[2]
    _name_ = definition[0]
    _version_ = definition[1]
    // Close the client if the reference goes away, so the service
    // process can clean things up.
    add_finalizer this:: close
    return this

  id -> int?:
    return _id_

  name -> string:
    return _name_

  major -> int:
    return _version_[0]

  minor -> int:
    return _version_[1]

  patch -> int:
    return _version_[2]

  close -> none:
    id := _id_
    if not id: return
    pid := _pid_
    _id_ = _name_ = _version_ = _pid_ = null
    remove_finalizer this
    ServiceResourceProxyManager_.unregister_all id
    rpc.invoke pid RPC_SERVICES_CLOSE_ id

  stringify -> string:
    return "service:$_name_@$(_version_.join ".")"

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

abstract class ServiceDefinition:
  name/string ::= ?
  _version_/List ::= ?

  _uuids_/List ::= []
  _versions_/List ::= []
  _manager_/ServiceManager_? := null

  _clients_/Set ::= {}  // Set<int>
  _clients_closed_/int := 0
  _clients_closed_signal_ ::= monitor.Signal

  _resources_/Map ::= {:}  // Map<int, Map<int, Object>>
  _resource_handle_next_/int := ?

  constructor .name --major/int --minor/int --patch/int=0:
    _version_ = [major, minor, patch]
    _resource_handle_next_ = random RESOURCE_HANDLE_LIMIT_

  abstract handle pid/int client/int index/int arguments/any-> any

  on_opened client/int -> none:
    // Override in subclasses.

  on_closed client/int -> none:
    // Override in subclasses.

  version -> string:
    return _version_.join "."

  stringify -> string:
    return "service:$name@$version"

  provides uuid/string major/int minor/int -> none:
    _uuids_.add uuid
    _versions_.add [major, minor]

  install -> none:
    if _manager_: throw "Already installed"
    _manager_ = ServiceManager_.instance
    _clients_closed_ = 0
    _uuids_.do: _manager_.listen it this

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
    return [ name, _version_, client ]

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

  _validate_ uuid/string major/int minor/int -> none:
    index := _uuids_.index_of uuid
    if index < 0: throw "$this does not provide service:$uuid"
    version := _versions_[index]
    if major != version[0]:
      throw "$this does not provide service:$uuid@$(major).x"
    if minor > version[1]:
      throw "$this does not provide service:$uuid@$(major).$(minor).x"

  _uninstall_ -> none:
    if not _resources_.is_empty: throw "Leaked $_resources_"
    _uuids_.do: _manager_.unlisten it
    _manager_ = null

abstract class ServiceResource implements rpc.RpcSerializable:
  _service_/ServiceDefinition? := ?
  _client_/int ::= ?
  _handle_/int? := null

  constructor ._service_ ._client_ --notifiable/bool=false:
    _handle_ = _service_._register_resource_ _client_ this notifiable

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
    _service_._manager_.notify _client_ handle notification

  close -> none:
    handle := _handle_
    if not handle: return
    service := _service_
    _handle_ = _service_ = null
    service._unregister_resource_ _client_ handle
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

  broker_/ServiceRpcBroker_ ::= ServiceRpcBroker_

  clients_/Map ::= {:}                // Map<int, int>
  clients_by_pid_/Map ::= {:}         // Map<int, Set<int>>

  services_by_uuid_/Map ::= {:}       // Map<string, ServiceDefinition>
  services_by_client_/Map ::= {:}     // Map<int, ServiceDefinition>

  constructor:
    set_system_message_handler_ SYSTEM_RPC_NOTIFY_ this
    broker_.register_procedure RPC_SERVICES_OPEN_:: | arguments _ pid |
      open pid arguments[0] arguments[1] arguments[2]
    broker_.register_procedure RPC_SERVICES_CLOSE_:: | arguments |
      close arguments
    broker_.register_procedure RPC_SERVICES_INVOKE_:: | arguments _ pid |
      client/int ::= arguments[0]
      service ::= services_by_client_[client]
      service.handle pid client arguments[1] arguments[2]
    broker_.register_procedure RPC_SERVICES_CLOSE_RESOURCE_:: | arguments |
      client/int ::= arguments[0]
      services_by_client_.get client --if_present=: | service/ServiceDefinition |
        resource/ServiceResource? := service._find_resource_ client arguments[1]
        if resource: resource.close
    broker_.install
    uninitialized = false

  static is_empty -> bool:
    return uninitialized or instance.services_by_uuid_.is_empty

  listen uuid/string service/ServiceDefinition -> none:
    services_by_uuid_[uuid] = service
    _client_.listen uuid

  unlisten uuid/string -> none:
    _client_.unlisten uuid
    services_by_uuid_.remove uuid

  open pid/int uuid/string major/int minor/int -> List:
    service/ServiceDefinition? ::= services_by_uuid_.get uuid
    if not service: throw "Unknown service:$uuid"
    service._validate_ uuid major minor
    client ::= assign_client_id_ pid
    services_by_client_[client] = service
    clients/Set ::= clients_by_pid_.get pid --init=(: {})
    clients.add client
    return service._open_ client

  notify client/int handle/int notification/any -> none:
    pid/int? := clients_.get client
    if not pid: return  // Already closed.
    process_send_ pid SYSTEM_RPC_NOTIFY_RESOURCE_ [client, handle, notification]
    if not is_processing_messages_: yield  // Yield to allow intra-process messages to be processed.

  close client/int -> none:
    pid/int? := clients_.get client
    if not pid: return  // Already closed.
    clients_.remove client
    // Unregister the client in the service client set.
    service/ServiceDefinition := services_by_client_[client]
    services_by_client_.remove client
    // Only unregister the client from the clients set
    // for the pid if we haven't already done so as part
    // of a call to $close_all.
    clients/Set? ::= clients_by_pid_.get pid
    if clients:
      clients.remove client
      if clients.is_empty: clients_by_pid_.remove pid
    service._close_ client

  close_all pid/int -> none:
    clients/Set? ::= clients_by_pid_.get pid
    if not clients: return
    // We avoid manipulating the clients set in the $close
    // method by taking ownership of it here.
    clients_by_pid_.remove pid
    task:: clients.do: close it

  on_message type/int gid/int pid/int message/any -> none:
    assert: type == SYSTEM_RPC_NOTIFY_
    kind/int ::= message[0]
    // The other process isn't necessarily the sender of the
    // notifications. They almost always come from the system
    // process and are sent as part of the discovery handshake.
    other/int ::= message[1]
    if kind == SERVICES_MANAGER_NOTIFY_ADD_PROCESS:
      broker_.add_process other
    else if kind == SERVICES_MANAGER_NOTIFY_REMOVE_PROCESS:
      broker_.remove_process other
      close_all other
    else:
      unreachable

  assign_client_id_ pid/int -> int:
    while true:
      guess := random CLIENT_ID_LIMIT_
      if clients_.contains guess: continue
      clients_[guess] = pid
      return guess

class ServiceRpcBroker_ extends broker.RpcBroker:
  pids_ ::= {}

  accept gid/int pid/int -> bool:
    return pids_.contains pid

  add_process pid/int -> none:
    pids_.add pid

  remove_process pid/int -> none:
    pids_.remove pid
    cancel_requests pid
