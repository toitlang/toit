// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rpc
import uuid
import device
import encoding.tpack as tpack

import protogen.rpc.pubsub_pb as pubsub_pb

/**
Support for PubSub messaging.

PubSub is an asynchronous messaging service that decouples publishers that
  send messages from subscribers that receive them. The publishers broadcast
  messages on a topic, and the messages are routed to subscribers interested
  in the topic. Use $publish to publish a message and $subscribe to subscribe
  to a message.

PubSub topics are either on-device (prefixed with $TOPIC_TYPE_DEVICE_STRING
  or $TOPIC_TYPE_DEVICE_MEMORY_STRING) or cloud (prefixed with
  $TOPIC_TYPE_CLOUD_STRING) topics.
Subscriptions to a cloud topic must be declared in the subscriber's .yaml.
  For example:
```
name: Cloud Subscriber
entrypoint: cloud_subscriber_example.toit

pubsub:
  subscriptions:
   - "cloud:example"
```
Use the trigger `on_pubsub_topic` to run an app when a message is available
  on a PubSub topic. For example
```
[...]
triggers:
  on_pubsub_topic:
   - "cloud:example"
```
A PubSub trigger will indirectly declare the necessary subscription.
*/

/** Invalid topic error string. */
ERR_INVALID_TOPIC ::= "INVALID_PUBSUB_TOPIC"
/** Invalid topic type error string. */
ERR_INVALID_TOPIC_TYPE ::= "INVALID_PUBSUB_TOPIC_TYPE"
/** Subscription not setup error string. */
ERR_SUBSCRIPTION_NOT_SETUP ::= "PUBSUB_SUBSCRIPTION_NOT_SETUP"
/** Invalid message error string. */
ERR_INVALID_MESSAGE ::= "INVALID_PUBSUB_MESSAGE"
/** Closed subscription error string.*/
ERR_SUBSCRIPTION_CLOSED ::= "PUBSUB_SUBSCRIPTION_CLOSED"

/** Unknown topic type. */
TOPIC_TYPE_UNKNOWN         ::= 0
/** Cloud topic type. */
TOPIC_TYPE_CLOUD           ::= 1
/** Device topic type. */
TOPIC_TYPE_DEVICE          ::= 2
/** Device memory topic type. */
TOPIC_TYPE_DEVICE_MEMORY   ::= 3

/** Cloud topic type string. */
TOPIC_TYPE_CLOUD_STRING ::= "cloud"
/** Device topic type string. */
TOPIC_TYPE_DEVICE_STRING ::= "device"
/** Device memory topic type string. */
TOPIC_TYPE_DEVICE_MEMORY_STRING ::= "device-memory"

topic_type_to_string_ type/int -> string:
  if type == TOPIC_TYPE_CLOUD:
    return TOPIC_TYPE_CLOUD_STRING
  if type == TOPIC_TYPE_DEVICE:
    return TOPIC_TYPE_DEVICE_STRING
  if type == TOPIC_TYPE_DEVICE_MEMORY:
    return TOPIC_TYPE_DEVICE_MEMORY_STRING
  throw ERR_INVALID_TOPIC_TYPE

topic_type_from_string_ str/string -> int:
  if str == TOPIC_TYPE_CLOUD_STRING:
    return TOPIC_TYPE_CLOUD
  if str == TOPIC_TYPE_DEVICE_STRING:
    return TOPIC_TYPE_DEVICE
  if str == TOPIC_TYPE_DEVICE_MEMORY_STRING:
    return TOPIC_TYPE_DEVICE_MEMORY
  throw ERR_INVALID_TOPIC_TYPE

/** Whether the $type is a valid topic type. */
is_valid_topic_type type/int -> bool:
  return type == TOPIC_TYPE_CLOUD or type == TOPIC_TYPE_DEVICE or type == TOPIC_TYPE_DEVICE_MEMORY

/**
A PubSub topic that consists of a type and a name.

The string representation of a topic is "$type:$name".
*/
class Topic:
  /** The name of the topic. */
  name/string ::= ?
  /** The type of the topic. */
  type/int ::= ?
  /**
  See $super.

  Valid input to $Topic.parse.
  */
  stringify/string ::= ?

  /**
  Constructs a topic with the given $type and $name.
  */
  constructor .type .name:
    stringify = "$(topic_type_to_string_ type):$name"

  /**
  Parses the $str as a topic.

  The string must have the form "$type:$name".

  Strings from $stringify are valid input.
  */
  constructor.parse str/string:
    parts := str.split --at_first=true ":"
    if parts.size != 2:
      throw ERR_INVALID_TOPIC
    type = topic_type_from_string_ parts[0]
    name = parts[1]
    stringify = str

  /**
  Constructs a topic from the given $data.

  The map produced by $as_map is valid input.
  */
  constructor.parse_map data/Map:
    type = data.get "type"
    if not is_valid_topic_type type:
      throw ERR_INVALID_TOPIC_TYPE
    name = data.get "name"
    stringify = "$(topic_type_to_string_ type):$name"

  /**
  Converts this topic to a map.

  Valid input to $Topic.parse_map.
  */
  as_map -> Map:
    return {"name": name, "type": type}

  /** Hash code of this topic. */
  hash_code -> int:
    return 11 * name.hash_code + 7 * type.hash_code

  /** Whether this is an on-device topic. */
  on_device_topic -> bool:
    return type == TOPIC_TYPE_DEVICE or type == TOPIC_TYPE_DEVICE_MEMORY

  /** See $super. */
  operator == other/any -> bool:
    return other is Topic
      and name == other.name
      and type == other.type

/**
The sender of a message.

A sender can either be external ($ExternalSender) or on the device
  ($DeviceSender).
*/
interface Sender:
  /** Whether this is an on-device sender. */
  is_device -> bool
  /** Whether this is an external sender. */
  is_external -> bool
  /**
  The name of the external sender.

  Returns null if the sender is on device.
  */
  external_name -> string?
  /**
  The job-ID of the on-device sender.

  Returns null if the sender is external.
  */
  job_id -> uuid.Uuid?
  /**
  The hardware-ID of the on-device sender.

  Returns null if the sender is external.
  */
  hardware_id -> uuid.Uuid?

/** An on device sender. */
class DeviceSender implements Sender:
  /** See $Sender.is_device. */
  is_device ::= true
  /** See $Sender.is_external. */
  is_external ::= false
  /** See $Sender.external_name. */
  external_name ::= null
  /** See $Sender.job_id. */
  job_id/uuid.Uuid
  /** See $Sender.hardware_id. */
  hardware_id/uuid.Uuid

  /**
  Constructs an on-device sender with the given $hardware_id and the
    given $job_id.
  */
  constructor .hardware_id .job_id:

/** An external sender. */
class ExternalSender implements Sender:
  /** See $Sender.is_device. */
  is_device ::= false
  /** See $Sender.is_external. */
  is_external ::= true
  /** See $Sender.external_name. */
  external_name/string
  /** See $Sender.job_id. */
  job_id ::= null
  /** See $Sender.hardware_id. */
  hardware_id ::= null

  /**
  Constructs an external sender with the $external_name.
  */
  constructor .external_name:

/**
A PubSub message.

A PubSub messages consists of a topic, a payload, and a sender.
*/
interface Message:
  /** The payload. */
  payload -> ByteArray
  /** The topic. */
  topic -> Topic
  /** The sender. */
  sender -> Sender

  /** Acknowledges all messages up until now. */
  acknowledge -> none

class Message_ implements Message:
  sender/Sender ::= ?
  topic/Topic ::= ?
  payload/ByteArray ::= ?
  acknowledged_/bool := false
  subscription_/TemporarySubscription? ::= ?

  constructor.rpc_ .topic data/ByteArray --device_hardware_id/uuid.Uuid=device.hardware_id --subscription/TemporarySubscription?=null:
    subscription_ = subscription

    msg := pubsub_pb.Message.deserialize
      tpack.Message.in data

    this.payload = msg.payload

    if msg.publisher_oneof_case == pubsub_pb.Message.PUBLISHER_DEVICE:
      job_id := uuid.Uuid msg.publisher_device.job_id
      hardware_id := msg.publisher_device.hardware_id.is_empty ? device_hardware_id : uuid.Uuid msg.publisher_device.hardware_id
      sender = DeviceSender hardware_id job_id
    else if msg.publisher_oneof_case == pubsub_pb.Message.PUBLISHER_EXTERNAL:
      sender = ExternalSender msg.publisher_external
    else:
      throw ERR_INVALID_MESSAGE

  acknowledge:
    if not acknowledged_:
      if subscription_:
        subscription_.acknowledge_
      else:
        acknowledge_ topic.stringify
      acknowledged_ = true

RPC_PUBSUB_READ ::= 700
RPC_PUBSUB_ACK ::= 701
RPC_PUBSUB_WRITE ::= 702
RPC_PUBSUB_REGISTER ::= 703
RPC_PUBSUB_UNREGISTER ::= 704
RPC_PUBSUB_HANDLE_READ ::= 705
RPC_PUBSUB_HANDLE_ACK ::= 706

/** A subscription for on-device topics. */
class TemporarySubscription extends rpc.CloseableProxy:
  topic/Topic

  /**
  Constructs a temporary subscription.

  The topic type must support temporary subscriptions.
  */
  constructor topic:
    this.topic = topic is Topic ? topic : Topic.parse topic
    if not this.topic.on_device_topic:
      throw ERR_INVALID_TOPIC_TYPE
    super
      rpc.invoke RPC_PUBSUB_REGISTER [topic.stringify]

  close_rpc_selector_: return RPC_PUBSUB_UNREGISTER

  /**
  Listens for messages on this subscription.

  When there is a message on the topic, calls the $callback block with the message.

  If the $blocking argument is true, then the call blocks until there is
    a message. If the $callback doesn't return, then the call will keep
    listening for messages.

  If the $auto_acknowledge argument is true, then all messages are
    acknowledged unless the $callback produced an exception.
  */
  listen --blocking/bool=true --auto_acknowledge/bool=true [callback]:
    if handle_ != null:
      subscribe_ --blocking=blocking --auto_acknowledge=auto_acknowledge
        :
          b/ByteArray? := read_ blocking
          b ? Message_.rpc_ this.topic b --subscription=this : null
        callback

  read_ blocking/bool -> ByteArray?:
    return rpc.invoke RPC_PUBSUB_HANDLE_READ [handle_, blocking]

  acknowledge_ -> none:
    rpc.invoke RPC_PUBSUB_HANDLE_ACK [handle_]

/**
Subscribes to the given $topic.

When there is a message on the topic, calls the $callback block with the message.

If the $blocking argument is true, then the call blocks until there is
  a message. If the $callback doesn't return, then the call will keep
  listening for messages.

If the $auto_acknowledge argument is true, then all messages are
  acknowledged unless the $callback produced an exception.

Subscriptions to a cloud topic must be declared in the subscriber's .yaml.
  For example:
```
name: Cloud Subscriber
entrypoint: cloud_subscriber_example.toit

pubsub:
  subscriptions:
   - "cloud:example"
```
*/
subscribe topic/string --blocking/bool=true --auto_acknowledge/bool=true [callback]:
  t := Topic.parse topic
  subscribe_ --blocking=blocking --auto_acknowledge=auto_acknowledge
    :
      b/ByteArray? := rpc.invoke RPC_PUBSUB_READ [t.stringify, blocking]
      b ? Message_.rpc_ t b : null
    callback

subscribe_ --blocking/bool=true --auto_acknowledge/bool=true [read] [callback]:
  while true:
    msg/Message? := read.call
    if msg == null:
      if blocking:
        continue
      else:
        break
    try:
      callback.call msg
    finally: | is_exception _ |
      if auto_acknowledge and not is_exception:
        msg.acknowledge

acknowledge_ topic/string -> none:
  rpc.invoke RPC_PUBSUB_ACK [topic]

/**
Publishes the $message on the given $topic.

Returns whether the message was published.

The topic format must be "$type:$name".

The message must either be a byte array or a string.
*/
publish topic/string message -> bool:
  payload := message is ByteArray ? message : message.to_byte_array
  return rpc.invoke RPC_PUBSUB_WRITE [topic, payload]
