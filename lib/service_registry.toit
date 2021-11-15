// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.ubjson as ubjson
import rpc_transport as rpc
import uuid

SERVICE_NAME_KEY_ ::= "service-name"
UUID_BYTES_KEY_ ::= "uuid-bytes"

/**
Registers a service with the given $name.

Returns a channel for the incoming requests.

Times out if the registration is unsuccessful.
*/
register_service_ name/string -> rpc.Channel_:
  uuid := uuid.uuid5 "register_service" "$random"
  channel := rpc.Channel_.create_local uuid
  args := {
    SERVICE_NAME_KEY_: name,
    UUID_BYTES_KEY_: uuid.to_byte_array
  }
  system_send_bytes_ SYSTEM_RPC_REGISTRY_REGISTER_ (ubjson.encode args)
  with_timeout --ms=50:
    channel.wait_for_open_status_
  return channel

/**
Unregisters the service with the given $name.
*/
unregister_service_ name/string -> none:
  args := {
    SERVICE_NAME_KEY_: name,
  }
  system_send_bytes_ SYSTEM_RPC_REGISTRY_UNREGISTER_ (ubjson.encode args)

/**
Connects to a service registered with $name.

Returns a channel to that service.

Times out if the connection is unsuccessful.
*/
connect_to_service_ name/string -> rpc.Channel_:
  uuid := uuid.uuid5 "connect_service" "$random"
  channel := rpc.Channel_.create_local uuid
  args := {
    SERVICE_NAME_KEY_: name,
    UUID_BYTES_KEY_: uuid.to_byte_array
  }
  system_send_bytes_ SYSTEM_RPC_REGISTRY_FIND_ (ubjson.encode args)
  with_timeout --ms=50:
    channel.wait_for_open_status_
  return channel
