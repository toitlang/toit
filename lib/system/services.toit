// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for defining and using services.
*/

import rpc
import rpc.broker
import monitor

import .discovery

// Notification kinds.
SERVICES_MANAGER_NOTIFY_OPEN_CLIENT  /int ::= 11
SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT /int ::= 12

// RPC procedure numbers used for opening and closing services from clients.
RPC_SERVICES_OPEN  /int         ::= 300
RPC_SERVICES_CLOSE /int         ::= 301
RPC_SERVICES_METHOD_START_ /int ::= 400

default_discovery_client_ ::= ServiceDiscoveryClient.lookup

abstract class ServiceClient:
  name/string ::= ?
  version_/List ::= ?

  pid_/int ::= ?
  procedure_/int? := null

  constructor.lookup name/string major/int minor/int --server/int?=null:
    if server:
      process_send_ server SYSTEM_RPC_NOTIFY_ [SERVICES_MANAGER_NOTIFY_OPEN_CLIENT, current_process_]
      pid_ = server
    else:
      pid_ = default_discovery_client_.discover name
    definition ::= rpc.invoke pid_ RPC_SERVICES_OPEN [name, major, minor]
    this.name = definition[0]
    version_ = definition[1]
    procedure_ = definition[2]
    add_finalizer this:: close

  major -> int:
    return version_[0]

  minor -> int:
    return version_[1]

  patch -> int:
    return version_[2]

  close -> none:
    if not procedure_: return
    procedure := procedure_
    procedure_ = null
    remove_finalizer this
    rpc.invoke pid_ RPC_SERVICES_CLOSE procedure

  stringify -> string:
    return "service:$name@$major.$minor.$patch"

  invoke_ index/int arguments/any -> any:
    if not procedure_: throw "Client closed"
    return rpc.invoke pid_ procedure_ [index, arguments]

abstract class ServiceDefinition:
  names_/List ::= ?
  versions_/List ::= ?
  manager_/ServiceManager_? := null
  procedure_/int? := null
  clients_/int := 0

  // TODO(kasper): Consider what happens if the same definition is installed
  // after being uninstalled. Do we need to use an extra latch for that?
  uninstalled_/monitor.Latch ::= monitor.Latch

  constructor name/string --major/int --minor/int --patch/int=0:
    names_ = [name]
    versions_ = [[major, minor, patch]]

  abstract handle client/int index/int arguments/any-> any

  name -> string:
    return names_.first

  version -> string:
    return versions_.first.join "."

  procedure -> int:
    return procedure_

  install -> none:
    manager_ = ServiceManager_.instance
    procedure_ = manager_.install this
    names_.do: manager_.listen it this

  wait -> none:
    uninstalled_.get

  uninstall -> none:
    names_.do: manager_.unlisten it
    manager_.uninstall procedure_
    clients_ = 0
    procedure_ = null
    manager_ = null
    uninstalled_.set 0

  open client/int -> none:
    clients_++

  close client/int -> none:
    if --clients_ == 0: uninstall

  alias name/string --major/int --minor/int -> none:
    names_.add name
    versions_.add [major, minor]

  stringify -> string:
    return "service:$name@$version"

  resolve name/string major/int minor/int -> List?:
    index := names_.index_of name
    if index < 0: return null
    version := versions_[index]
    if major != version[0]:
      throw "Cannot find service:$name@$(major).x, found $this"
    if minor > version[1]:
      throw "Cannot find service:$name@$(major).$(minor).x, found $this"
    return [names_[0], versions_[0], procedure_]

class ServiceManager_ implements SystemMessageHandler_:
  static instance := ServiceManager_

  broker_/ServiceRpcBroker_ ::= ServiceRpcBroker_

  procedures_/Set ::= {}              // Set<int>
  procedures_by_client_/Map ::= {:}   // Map<int, Set<int>>

  services_by_name_/Map ::= {:}       // Map<string, ServiceDefinition>
  services_by_procedure_/Map ::= {:}  // Map<int, ServiceDefinition>

  counts_by_procedure_/Map ::= {:}    // Map<int, Map<int, int>>

  constructor:
    set_system_message_handler_ SYSTEM_RPC_NOTIFY_ this
    broker_.register_procedure RPC_SERVICES_OPEN:: | arguments _ pid |
      open pid arguments[0] arguments[1] arguments[2]
    broker_.register_procedure RPC_SERVICES_CLOSE:: | arguments _ pid |
      close pid arguments
    broker_.install

  install service/ServiceDefinition -> int:
    procedure := random_procedure_
    services_by_procedure_[procedure] = service
    broker_.register_procedure procedure:: | arguments _ pid |
      service.handle pid arguments[0] arguments[1]
    return procedure

  uninstall procedure/int -> none:
    broker_.unregister_procedure procedure
    services_by_procedure_.remove procedure
    procedures_.remove procedure
    counts/Map? ::= counts_by_procedure_.get procedure
    if not counts: return
    counts_by_procedure_.remove procedure
    counts.do: | client/int count/int |
      procedures/Set? := procedures_by_client_.get client
      if not procedures: continue.do
      procedures.remove procedure
      if procedures.is_empty: procedures_by_client_.remove client

  listen name/string service/ServiceDefinition -> none:
    services_by_name_[name] = service
    default_discovery_client_.listen name

  unlisten name/string -> none:
    default_discovery_client_.unlisten name
    services_by_name_.remove name

  open client/int name/string major/int minor/int -> List?:
    service/ServiceDefinition ::= services_by_name_[name]
    resolved ::= service.resolve name major minor
    if not resolved: return null
    procedure ::= service.procedure
    counts/Map ::= counts_by_procedure_.get procedure --init=(: {:})
    count/int ::= counts.update client --init=(: 0): it + 1
    if count > 1: return resolved
    procedures/Set ::= procedures_by_client_.get client --init=(: {})
    procedures.add procedure
    task:: service.open client
    return resolved

  close client/int procedure/int -> none:
    counts/Map? ::= counts_by_procedure_.get procedure
    if not counts: throw "No such client (pid=$client)"
    count/int ::= counts.update client: it - 1
    if count > 0: return
    service/ServiceDefinition := services_by_procedure_[procedure]
    procedures/Set ::= procedures_by_client_.get client
    counts.remove client
    if counts.is_empty: counts_by_procedure_.remove procedure
    procedures.remove procedure
    if procedures.is_empty: procedures_by_client_.remove client
    task:: service.close client

  close_all client/int -> none:
    procedures/Set? ::= procedures_by_client_.get client
    if not procedures: return
    closed/List ::= []
    procedures.do: | procedure/int |
      counts/Map? ::= counts_by_procedure_.get procedure
      if not counts: continue.do
      counts.remove client
      if counts.is_empty: counts_by_procedure_.remove procedure
      service/ServiceDefinition := services_by_procedure_[procedure]
      closed.add service
    procedures_by_client_.remove client
    task:: closed.do: it.close client

  on_message type/int gid/int pid/int message/any -> none:
    assert: type == SYSTEM_RPC_NOTIFY_
    kind/int ::= message[0]
    client/int ::= message[1]
    if kind == SERVICES_MANAGER_NOTIFY_OPEN_CLIENT:
      broker_.add_client client
    else if kind == SERVICES_MANAGER_NOTIFY_CLOSE_CLIENT:
      broker_.remove_client client
      close_all client
    else:
      unreachable

  random_procedure_ -> int:
    while true:
      guess := (random 1_000_000_000) + RPC_SERVICES_METHOD_START_
      if procedures_.contains guess: continue
      procedures_.add guess
      return guess

class ServiceRpcBroker_ extends broker.RpcBroker:
  clients_ ::= {}

  accept gid/int pid/int -> bool:
    return clients_.contains pid

  add_client pid/int -> none:
    clients_.add pid

  remove_client pid/int -> none:
    clients_.remove pid
    cancel_requests pid
