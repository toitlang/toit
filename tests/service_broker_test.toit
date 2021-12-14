// Copyright (C) 2021 Toitware ApS. All rights reserved.

import ..tools.service_registry
import service_registry show SERVICE_NAME_KEY_ UUID_BYTES_KEY_
import encoding.ubjson as ubjson
import rpc_transport as rpc
import expect show *
import uuid

main:
  // Register a service channel in the kernel.
  service_channel_id ::= uuid.uuid5 "test" "channel"
  service_channel := rpc.Channel_.create_local service_channel_id
  service_name ::= "test-service"
  bytes := ubjson.encode {
    SERVICE_NAME_KEY_ : service_name,
    UUID_BYTES_KEY_ : service_channel_id.to_byte_array
  }
  system_send_bytes_ SYSTEM_RPC_REGISTRY_REGISTER_ bytes

  // Wait until a service channel has been registered.
  service_channel.wait_for_open_status_

  // Send a channel to the service.
  channel_id ::= uuid.uuid5 "test" "channel to service"
  channel := rpc.Channel_.create_local channel_id
  bytes = ubjson.encode {
    SERVICE_NAME_KEY_ : service_name,
    UUID_BYTES_KEY_ : channel_id.to_byte_array
  }
  system_send_bytes_ SYSTEM_RPC_REGISTRY_FIND_ bytes

  // Open the service side of the channel.
  channel_id_bytes := service_channel.receive
  channel_other_end := rpc.Channel_.open channel_id

  // Test that the channel sent to the service works.
  channel.send 0 42 #[1,2,3]
  frame := channel_other_end.receive
  expect_equals 0 frame.stream_id
  expect_equals 42 frame.bits
  expect_bytes_equal #[1,2,3] frame.bytes

  bytes = ubjson.encode {
    SERVICE_NAME_KEY_ : service_name
  }
  system_send_bytes_ SYSTEM_RPC_REGISTRY_UNREGISTER_ bytes
