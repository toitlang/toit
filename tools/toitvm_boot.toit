// Copyright (C) 2019 Toitware ApS. All rights reserved.

// This program is a wrapper program used by toitc with one purpose only: To make stack traces readable.

import .ar
import debug.rpc show RPC_ECHO
import .debug_message
import .snapshot
import .mirror
import .rpc
import .service_registry
import .logging
import encoding.ubjson as ubjson
import log.rpc as log
import log
import monitor
import debug.rpc as debug_lib

class ToitcProcessManager implements SystemMessageHandler_:
  snapshot_bundle / ByteArray ::= ?
  child   := null
  program := null

  constructor .snapshot_bundle:
    // First setup the handlers before launching the application.
    set_system_message_handler_ SYSTEM_TERMINATED_ this
    set_system_message_handler_ SYSTEM_MIRROR_MESSAGE_ this
    task_cache := monitor.TaskCache_
    rpc_broker := RpcBroker task_cache
    register_rpc rpc_broker
    set_system_message_handler_ SYSTEM_RPC_CHANNEL_LEGACY_ rpc_broker
    service_broker := ServiceBroker NoopDescriptorRegistry task_cache
    set_system_message_handler_ SYSTEM_RPC_REGISTRY_REGISTER_ service_broker
    set_system_message_handler_ SYSTEM_RPC_REGISTRY_UNREGISTER_ service_broker
    set_system_message_handler_ SYSTEM_RPC_REGISTRY_FIND_ service_broker
    ar_reader := ArReader.from_bytes snapshot_bundle
    offsets := ar_reader.find --offsets SnapshotBundle.SNAPSHOT_NAME
    // Start the application process.
    child = launch_snapshot snapshot_bundle offsets.from offsets.to true

  register_rpc rpc/RpcBroker -> none:
    // Expect args format [ names/List<string>?, level/int, message/string, tags/Map<String, any>?].
    rpc.register_procedure log.RPC_SYSTEM_LOG :: | args |
      print_
        log_format args[0] args[1] args[2] args[3] --with_timestamp=false

    rpc.register_procedure debug_lib.RPC_SYSTEM_DEBUG::
      str := decode_debug_message it[0] snapshot_bundle
      print_ str

  on_message type gid pid args:
    if type == SYSTEM_MIRROR_MESSAGE_:
      // For example stack traces, or profile reports.
      encoded_message := args
      if pid == child: handle_mirror_message encoded_message
      else: print_for_manually_decoding_ encoded_message
    else if type == SYSTEM_TERMINATED_:
      value := args
      exit value

  handle_mirror_message encoded_message/ByteArray -> none:
    // The snapshot is lazily parsed when debugging information is needed.
    if not program: program = (SnapshotBundle snapshot_bundle).decode
    // Handle stack traces in ubjson format.
    mirror ::= decode encoded_message program:
      print_on_stderr_ "Mirror creation failed: $it"
      return
    print_on_stderr_ mirror
    print_on_stderr_ ""

class NoopDescriptorRegistry implements DescriptorRegistry:
  register_descriptor gid/int object/Descriptor -> int:
    return 0
  unregister_descriptor gid/int descriptor/int -> none:

main:
  // The snapshot for the application program is passed in hatch_args_
  snapshot_bundle ::= hatch_args_
  if snapshot_bundle is not ByteArray:
    print_on_stderr_ "toitc_boot must be provided a snapshot"
    exit 1
  ToitcProcessManager snapshot_bundle
  while true:
    // Process messages.
    process_messages_
    // Allow other tasks to run (e.g those started by RPC handler).
    yield
    // Yield to scheduler to allow other processes to run (this process will now wait for
    // messages), iff there is nothing else to do.
    if task.next_running_ == task:
      __yield__

/**
Starts a new process using the given $snapshot in the range [$from..$to[.

Passes the arguments of this process if $pass_arguments is set.
*/
launch_snapshot snapshot/ByteArray from/int to/int pass_arguments/bool:
  #primitive.snapshot.launch
