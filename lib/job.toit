// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rpc
import serialization
import pubsub

/**
Information on why an application has been started.
*/

RPC_SYSTEM_JOB_TRIGGER_ ::= 200

TRIGGER_UNKNOWN_    ::= 0
TRIGGER_ON_BOOT_    ::= 1
TRIGGER_ON_INSTALL_ ::= 2
TRIGGER_INTERVAL_   ::= 3
TRIGGER_CRON_       ::= 4
TRIGGER_PUBSUB_     ::= 6
TRIGGER_GPIO_       ::= 7

/**
The trigger that initiated the job execution.
*/
trigger -> Trigger:
  data := rpc.invoke RPC_SYSTEM_JOB_TRIGGER_ []
  return Trigger.deserialize data

/**
Superclass of all trigger classes.
*/
abstract class Trigger:
  abstract type_ -> int

  constructor:

  constructor.deserialize data/ByteArray?:
    if data:
      values := serialization.deserialize data
      type := values[0]
      if type == TRIGGER_ON_BOOT_: return OnBootTrigger
      if type == TRIGGER_ON_INSTALL_: return OnInstallTrigger
      if type == TRIGGER_INTERVAL_: return IntervalTrigger (Duration values[1])
      if type == TRIGGER_CRON_: return CronTrigger
      if type == TRIGGER_PUBSUB_ : return PubSubTrigger (pubsub.Topic.parse values[1])
      if type == TRIGGER_GPIO_ : return GpioTrigger values[1]
    return UnknownTrigger

  serialize -> ByteArray:
    return serialization.serialize [type_]

/**
Trigger class when the application was started for an unknown reason.
*/
class UnknownTrigger extends Trigger:
  type_ ::= TRIGGER_UNKNOWN_

/**
Trigger class when the application was started on boot.
*/
class OnBootTrigger extends Trigger:
  type_ ::= TRIGGER_ON_BOOT_

/**
Trigger class when the application was started on install.
*/
class OnInstallTrigger extends Trigger:
  type_ ::= TRIGGER_ON_INSTALL_


/**
Trigger class when the application was started because of an elapsed interval.
*/
class IntervalTrigger extends Trigger:
  type_ ::= TRIGGER_INTERVAL_

  /** The elapsed interval. */
  interval/Duration ::= ?

  constructor .interval:

  serialize -> ByteArray:
    return serialization.serialize [
      type_,
      interval.in_ns,
    ]

/**
Trigger class when the application was started based on a schedule (cron).
*/
class CronTrigger extends Trigger:
  type_ ::= TRIGGER_CRON_

/**
Trigger class when the application was started due to a received pubsub message.
*/
class PubSubTrigger extends Trigger:
  type_ ::= TRIGGER_PUBSUB_

  /** The topic of the pubsub message. */
  topic/pubsub.Topic ::= ?

  constructor .topic:

  serialize -> ByteArray:
    return serialization.serialize [type_, topic.stringify]

/**
Trigger class when the application was started due to a gpio pin change.
*/
class GpioTrigger extends Trigger:
  type_ ::= TRIGGER_GPIO_

  /** The pin that changed. */
  pin/int ::= ?

  constructor .pin:

  serialize -> ByteArray:
    return serialization.serialize [
      type_,
      pin,
    ]
