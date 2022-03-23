// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for defining and using services.
*/

import rpc
import rpc.broker
import monitor

RPC_SERVICES_MANAGER_INSTALL  ::= 200
RPC_SERVICES_MANAGER_LISTEN   ::= 201
RPC_SERVICES_MANAGER_UNLISTEN ::= 202

RPC_SERVICES_DISCOVER         ::= 210
RPC_SERVICES_RESOLVE          ::= 211

RPC_SERVICES_MANAGER_NOTIFY_OPEN_CLIENT  ::= 300
RPC_SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT ::= 301

abstract class ServiceClient:
  name/string ::= ?
  version_/List ::= ?

  pid_/int ::= ?
  procedure_/int ::= ?

  constructor.lookup name/string major/int minor/int:
    pid_ = rpc.invoke RPC_SERVICES_DISCOVER name
    definition := rpc.invoke pid_ RPC_SERVICES_RESOLVE [name, major, minor]
    this.name = definition[0]
    version_ = definition[1]
    procedure_ = definition[2]

  stringify -> string:
    return "client:$name@$major.$minor.$patch"

  major -> int:
    return version_[0]

  minor -> int:
    return version_[1]

  patch -> int:
    return version_[2]

  invoke_ index/int arguments/any -> any:
    return rpc.invoke pid_ procedure_ [index, arguments]

abstract class ServiceDefinition:
  names_/List ::= ?
  versions_/List ::= ?
  manager_/ServiceManager_? := null
  procedure_/int? := null

  // TODO(kasper): Consider what happens if the same definition is installed
  // after being uninstalled. Do we need to use an extra latch for that?
  uninstalled_/monitor.Latch ::= monitor.Latch

  constructor name/string --major/int --minor/int --patch/int=0:
    names_ = [name]
    versions_ = [[major, minor, patch]]

  abstract handle index/int arguments/any -> any

  on_client_opened pid/int open/int -> none:
    // Do nothing. Overridden in subclasses.

  on_client_closed pid/int open/int -> none:
    if open == 0: uninstall

  install -> none:
    manager_ = ServiceManager_.instance
    procedure_ = manager_.install this
    names_.do: manager_.listen it this

  wait -> none:
    uninstalled_.get

  uninstall -> none:
    names_.do: manager_.unlisten it
    manager_.uninstall procedure_
    procedure_ = null
    manager_ = null
    uninstalled_.set 0

  alias name/string --major/int --minor/int -> none:
    names_.add name
    versions_.add [major, minor]

  resolve name/string major/int minor/int -> List?:
    index := names_.index_of name
    if index < 0: return null
    version := versions_[index]
    if major != version[0]: throw "Wrong major version: $version[0] != $major"
    if minor > version[1]: throw "Wrong minor version: $version[1] < $minor"
    return [names_[0], versions_[0], procedure_]

class ServiceManager_ implements SystemMessageHandler_:
  static instance := ServiceManager_

  broker_/ServiceRpcBroker_ ::= ServiceRpcBroker_
  procedures_/Set ::= {}

  services_by_name_/Map ::= {:}
  services_by_procedure_/Map ::= {:}

  constructor:
    set_system_message_handler_ SYSTEM_SERVICE_NOTIFY_ this
    broker_.register_procedure RPC_SERVICES_RESOLVE:: | arguments |
      resolve arguments[0] arguments[1] arguments[2]
    broker_.install
    rpc.invoke RPC_SERVICES_MANAGER_INSTALL null

  install service/ServiceDefinition -> int:
    procedure := random_procedure_
    services_by_procedure_[procedure] = service
    broker_.register_procedure procedure:: | arguments |
      service.handle arguments[0] arguments[1]
    return procedure

  uninstall procedure/int -> none:
    broker_.unregister_procedure procedure
    services_by_procedure_.remove procedure
    procedures_.remove procedure

  listen name/string service/ServiceDefinition -> none:
    services_by_name_[name] = service
    rpc.invoke RPC_SERVICES_MANAGER_LISTEN name

  unlisten name/string -> none:
    rpc.invoke RPC_SERVICES_MANAGER_UNLISTEN name
    services_by_name_.remove name

  resolve name/string major/int minor/int -> List?:
    service/ServiceDefinition := services_by_name_[name]
    return service.resolve name major minor

  on_message type/int gid/int pid/int message/any -> none:
    assert: type == SYSTEM_SERVICE_NOTIFY_
    kind := message[0]
    client := message[1]
    if kind == RPC_SERVICES_MANAGER_NOTIFY_OPEN_CLIENT:
      open := broker_.add_client client
      task:: services_by_procedure_.do --values: | service/ServiceDefinition |
        service.on_client_opened client open
    else if kind == RPC_SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT:
      open := broker_.remove_client client
      task:: services_by_procedure_.do --values: | service/ServiceDefinition |
        service.on_client_closed client open
    else:
      unreachable

  random_procedure_ -> int:
    while true:
      guess := (random 1_000_000_000) + 1_000
      if procedures_.contains guess: continue
      procedures_.add guess
      return guess

class ServiceRpcBroker_ extends broker.RpcBroker:
  clients_ ::= {}

  accept gid/int pid/int -> bool:
    return clients_.contains pid

  add_client pid/int -> int:
    clients_.add pid
    return clients_.size

  remove_client pid/int -> int:
    clients_.remove pid
    cancel_requests pid
    return clients_.size
