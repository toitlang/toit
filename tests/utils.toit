// Copyright (C) 2020 Toitware ApS. All rights reserved.

import uuid
import log
import monitor

import ..system.kernel.console_connector
import ..system.kernel.kv_store
import ..system.kernel.context as context
import ..system.kernel.trigger
import ..system.kernel.pubsub
import ..system.kernel.queues
import ..system.kernel.flash_registry
import ..system.kernel.events
import ..system.kernel.scheduler
import .system_process_test


class DummyTrigger implements Trigger:
  trigger:

class TestStore implements FlashStore:
  backing_ ::= {:}

  get key/Key:
    return backing_.get key

  remove key/Key -> bool:
    backing_.remove key
    return true

  set key/Key value/ByteArray -> bool:
    backing_[key] = value
    return true

  repair -> bool:
    return true

  delete -> bool:
    backing_.clear
    return true

  clear -> bool:
    return delete

  compact -> bool:
    return true

  values -> List:
    return backing_.values

class TestKernelJobConfig implements context.JobContext:
  signals := monitor.SignalDispatcher

  store name/string -> SerializedStore:
    return SerializedStore name TestStore

  namespace_store name/string -> NamespaceStore:
    return NamespaceStore name TestStore

  console_connector -> ConsoleConnector:
    return ConsoleConnector null (NamespaceStore "console_connector" TestStore)

  logger := log.Logger log.DEBUG_LEVEL log.DefaultTarget --name="test_logger"

  pubsub_manager -> PubSubManager:
    flash := FlashRegistry.scan
    queues := QueuesManager flash
    scheduler := Scheduler 0
    events := EventManager scheduler queues
    return PubSubManager queues events scheduler log.default

  scheduler_notifier -> Trigger:
    return DummyTrigger

  system_api: throw "UNIMPLEMENTED"
