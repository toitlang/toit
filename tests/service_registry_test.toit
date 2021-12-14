// Copyright (C) 2021 Toitware ApS. All rights reserved.

import expect show *
import monitor
import rpc_transport as rpc
import service_registry show *
import uuid

main:
  service_name := "service_registry_test-test-service"
  incoming_channel := register_service_ service_name

  expect_throw "DEADLINE_EXCEEDED":
    register_service_ service_name

  expect_throw "DEADLINE_EXCEEDED":
    connect_to_service_ "unknown-service-name"

  client_side := null
  latch := monitor.Latch
  task::
    client_side = connect_to_service_ service_name
    latch.set 1
  client_request_frame := incoming_channel.receive
  server_side := rpc.Channel_.open (uuid.Uuid client_request_frame.bytes)
  latch.get

  client_side.send 0 0 #[1,2,3]
  frame := server_side.receive
  expect_equals 0 frame.stream_id
  expect_equals 0 frame.bits
  expect_bytes_equal #[1,2,3] frame.bytes

  server_side.send 1 1 #[2,3,4]
  frame = client_side.receive
  expect_equals 1 frame.stream_id
  expect_equals 1 frame.bits
  expect_bytes_equal #[2,3,4] frame.bytes

  client_side.close
  server_side.close

  unregister_service_ service_name
  // Give the kernel time to process the unregister.
  sleep --ms=100
