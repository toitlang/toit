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
SERVICES_MANAGER_NOTIFY_OPEN_CLIENT  /int ::= 0
SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT /int ::= 1

// RPC procedure numbers used for using services from clients.
RPC_SERVICES_OPEN_           /int ::= 300
RPC_SERVICES_CLOSE_          /int ::= 301
RPC_SERVICES_INVOKE_         /int ::= 302
RPC_SERVICES_CLOSE_RESOURCE_ /int ::= 303

// Internal limits.
CLIENT_ID_LIMIT_       /int ::= 0x3fff_ffff
RESOURCE_HANDLE_LIMIT_ /int ::= 0x3fff_ffff

_client_ /ServiceDiscoveryService ::= ServiceDiscoveryServiceClient.lookup

abstract class ServiceClient:
  _name_/string ::= ?
  _version_/List ::= ?
  _pid_/int? ::= ?
  _id_/int? := null

  constructor.lookup name/string major/int minor/int --server/int?=null:
    pid/int? := null
    if server:
      process_send_ server SYSTEM_RPC_NOTIFY_ [SERVICES_MANAGER_NOTIFY_OPEN_CLIENT, current_process_]
      pid = server
    else:
      pid = _client_.discover name
      if not pid: throw "Cannot find service:$name"
    // Open the client by doing a RPC-call to the discovered process.
    // This returns the client id necessary for invoking service methods.
    definition ::= rpc.invoke pid RPC_SERVICES_OPEN_ [name, major, minor]
    _name_ = definition[0]
    _version_ = definition[1]
    _pid_ = pid
    _id_ = definition[2]
    // Close the client if the reference goes away, so the service
    // process can clean things up.
    add_finalizer this:: close

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
    _id_ = null
    remove_finalizer this
    rpc.invoke _pid_ RPC_SERVICES_CLOSE_ id

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
    rpc.invoke _pid_ RPC_SERVICES_CLOSE_RESOURCE_ [id, handle]

abstract class ServiceDefinition:
  _names_/List ::= ?
  _versions_/List ::= ?
  _manager_/ServiceManager_? := null

  _clients_/Set ::= {}     // Set<int>
  _resources_/Map ::= {:}  // Map<int, Map<int, Object>>
  _resource_handle_next_/int := ?

  // TODO(kasper): Consider what happens if the same definition is installed
  // after being uninstalled. Do we need to use an extra latch for that?
  _uninstalled_/monitor.Latch ::= monitor.Latch

  constructor name/string --major/int --minor/int --patch/int=0:
    _names_ = [name]
    _versions_ = [[major, minor, patch]]
    _resource_handle_next_ = random RESOURCE_HANDLE_LIMIT_

  abstract handle pid/int client/int index/int arguments/any-> any

  on_opened client/int -> none:
    // Override in subclasses.

  on_closed client/int -> none:
    // Override in subclasses.

  name -> string:
    return _names_.first

  version -> string:
    return _versions_.first.join "."

  stringify -> string:
    return "service:$name@$version"

  alias name/string --major/int --minor/int -> none:
    _names_.add name
    _versions_.add [major, minor]

  install -> none:
    if _manager_: throw "Already installed"
    _manager_ = ServiceManager_.instance
    _names_.do: _manager_.listen it this

  uninstall -> none:
    if not _manager_: return
    _clients_.do: _manager_.close it
    if _manager_: _uninstall_

  resource client/int handle/int -> ServiceResource:
    return _find_resource_ client handle

  wait -> none:
    _uninstalled_.get

  _open_ client/int -> List:
    _clients_.add client
    catch --trace: on_opened client
    return [ _names_[0], _versions_[0], client ]

  _close_ client/int -> none:
    _clients_.remove client
    resources ::= _resources_.get client
    if resources:
      // Iterate over a copy of the values, so we can remove
      // entries from the map when closing resources.
      resources.values.do: | resource/ServiceResource |
        catch --trace: resource.close
    catch --trace: on_closed client
    if _clients_.is_empty: _uninstall_

  _register_resource_ client/int resource/ServiceResource -> int:
    handle ::= _new_resource_handle_
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

  _new_resource_handle_ -> int:
    handle ::= _resource_handle_next_
    next ::= handle + 1
    _resource_handle_next_ = (next >= RESOURCE_HANDLE_LIMIT_) ? 0 : next
    return handle

  _validate_ name/string major/int minor/int -> none:
    index := _names_.index_of name
    if index < 0: throw "Cannot find service$name, found $this"
    version := _versions_[index]
    if major != version[0]:
      throw "Cannot find service:$name@$(major).x, found $this"
    if minor > version[1]:
      throw "Cannot find service:$name@$(major).$(minor).x, found $this"

  _uninstall_ -> none:
    if not _resources_.is_empty: throw "Leaked $_resources_"
    _names_.do: _manager_.unlisten it
    _manager_ = null
    _uninstalled_.set 0

abstract class ServiceResource implements rpc.RpcSerializable:
  _service_/ServiceDefinition? := ?
  _client_/int ::= ?
  _handle_/int? := null

  constructor ._service_ ._client_:
    _handle_ = _service_._register_resource_ _client_ this

  abstract on_closed -> none

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

  handle_ -> int:
    return _handle_

  close:
    handle := _handle_
    if not handle: return
    _handle_ = null
    remove_finalizer this
    catch --trace:
      // TODO(kasper): Should we avoid using the task deadline here
      // and use our own? If we're timing out and trying to call
      // close after timing out, it should still work.
      critical_do: client_._close_resource_ handle

class ServiceManager_ implements SystemMessageHandler_:
  static instance := ServiceManager_

  broker_/ServiceRpcBroker_ ::= ServiceRpcBroker_

  clients_/Map ::= {:}                // Map<int, int>
  clients_by_pid_/Map ::= {:}         // Map<int, Set<int>>

  services_by_name_/Map ::= {:}       // Map<string, ServiceDefinition>
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
      service ::= services_by_client_[client]
      resource/ServiceResource? := service._find_resource_ client arguments[1]
      if resource: resource.close
    broker_.install

  listen name/string service/ServiceDefinition -> none:
    services_by_name_[name] = service
    _client_.listen name

  unlisten name/string -> none:
    _client_.unlisten name
    services_by_name_.remove name

  open pid/int name/string major/int minor/int -> List:
    service/ServiceDefinition? ::= services_by_name_[name]
    if not service: throw "Unknown service $name"
    service._validate_ name major minor
    client ::= assign_client_id_ pid
    services_by_client_[client] = service
    clients/Set ::= clients_by_pid_.get pid --init=(: {})
    clients.add client
    return service._open_ client

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
    requester/int ::= message[1]
    if kind == SERVICES_MANAGER_NOTIFY_OPEN_CLIENT:
      broker_.add_process requester
    else if kind == SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT:
      broker_.remove_process requester
      close_all requester
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
