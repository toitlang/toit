// Copyright (C) 2021 Toitware ApS.
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

import encoding.ubjson as ubjson
import log
import monitor
import rpc_transport as rpc
import service_registry show SERVICE_NAME_KEY_ UUID_BYTES_KEY_
import uuid

interface Descriptor:
  close -> none

class Service:
  channel/rpc.Channel_
  gid/int
  descriptor/int?

  constructor .channel .gid .descriptor:

interface DescriptorRegistry:
  register_descriptor gid/int object/Descriptor -> int
  unregister_descriptor gid/int descriptor/int -> none


class ServiceBroker implements SystemMessageHandler_:
  descriptor_registry_/DescriptorRegistry
  task_cache_/monitor.TaskCache_
  services_ ::= {:}  // Map<string, Service>

  constructor .descriptor_registry_  .task_cache_:

  on_message type/int gid/int pid/int args:
    if args is not Map: return
    service_name := args.get SERVICE_NAME_KEY_ --if_absent=:
      // $on_message cannot cause recursive message processing (that is send
      // a system message). This means that error reporting cannot use print
      // or the kernel logger.
      debug "[SERVICE REGISTRY] missing service"
      // TODO(Lau): Report error (https://github.com/toitware/toit/issues/4128).
      return
    if type == SYSTEM_RPC_REGISTRY_REGISTER_:
      if services_.contains service_name:
        debug "[SERVICE REGISTRY] register: service already exists"
        // TODO(Lau): Report error (https://github.com/toitware/toit/issues/4128).
        return
      if not args.contains UUID_BYTES_KEY_:
        debug "[SERVICE REGISTRY] register: missing uuid bytes"
        // TODO(Lau): Report error (https://github.com/toitware/toit/issues/4128).
        return
      channel_uuid := uuid.Uuid args[UUID_BYTES_KEY_]
      channel := null
      e := catch --trace:
        channel = rpc.Channel_.open channel_uuid
      if e == rpc.Channel_.NO_SUCH_CHANNEL_ERROR:
        return
      assert: e == null

      descriptor := descriptor_registry_.register_descriptor
        gid
        ServiceDescriptor service_name this
      services_[service_name] = Service channel gid descriptor
    else if type == SYSTEM_RPC_REGISTRY_FIND_:
      if not args.contains UUID_BYTES_KEY_:
        debug "[SERVICE REGISTRY] find registry: missing uuid bytes"
        // TODO(Lau): Report error (https://github.com/toitware/toit/issues/4128).
        return
      services_.get service_name --if_present=: | service |
        // Send has a timeout to ensure that we make progress.
        task_cache_.run ::
          e := catch --trace:
            with_timeout --ms=100:
              ignore_stream_id := 0
              ignore_header := 0
              service.channel.send ignore_stream_id ignore_header args[UUID_BYTES_KEY_]
          if e: debug "[CHANNEL REGISTRY] find registry: $e"
    else:
      assert: type == SYSTEM_RPC_REGISTRY_UNREGISTER_
      service := services_.get service_name --if_absent=: return
      descriptor_registry_.unregister_descriptor service.gid service.descriptor
      unregister_service service_name

  unregister_service id/string:
    services_.remove id

class ServiceDescriptor implements Descriptor:
  service_name/string
  service_broker/ServiceBroker

  constructor .service_name .service_broker:

  close -> none:
    service_broker.unregister_service service_name
