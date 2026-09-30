// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor
import ..att as att
import ..gatt as gatt
import .api as api
import ..timeouts as timeouts

/** Whether $index is a GATT client operation ($ClientOperations.invoke). */
is-client-operation index/int -> bool:
  return OPERATIONS_.contains index

OPERATIONS_ ::= {
  api.CENTRAL-REVISION, api.CENTRAL-CHECKED, api.CENTRAL-MONITOR, api.CENTRAL-SUBSCRIBE,
  api.CENTRAL-SUBSCRIPTION-READY, api.CENTRAL-SUBSCRIPTION-NEXT, api.CENTRAL-UNSUBSCRIBE,
  api.CENTRAL-READ, api.CENTRAL-WRITE, api.CENTRAL-WRITE-COMMAND, api.CENTRAL-SERVICES,
  api.CENTRAL-CHARACTERISTICS, api.CENTRAL-INCLUDED, api.CENTRAL-READ-BY-UUID,
  api.CENTRAL-READ-MULTIPLE, api.CENTRAL-DESCRIPTORS,
}

/**
The GATT client operations of one ATT client and its subscriptions, for a
  central connection or a peripheral session alike.
*/
class ClientOperations:
  client_/att.Client
  subscriptions_/Map ::= {:}
  next-subscription_/int := 0

  constructor .client_:

  /**
  Runs a client operation and returns its RPC reply: [true, result], or
    [false, request, handle, code] for the peer's ATT error.
  */
  reply index/int arguments/List -> List:
    // RPC carries strings; the peer's ATT errors become a reply.
    error := catch --unwind=(: it is string):
      return [true, invoke index arguments]
    if error is att.AttributeError: return [false, error.request, error.handle, error.code]
    throw error.stringify

  /** Cancels every subscription's worker. */
  cancel -> none:
    subscriptions_.values.do: | subscription/Subscription_ | subscription.cancel

  /** Waits until every subscription's worker ended. */
  wait-ended -> none:
    subscriptions_.values.do: | subscription/Subscription_ | subscription.wait-ended

  invoke index/int arguments/List --revision/int?=null -> any:
    if index == api.CENTRAL-REVISION:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      return client_.database-revision
    if index == api.CENTRAL-CHECKED:
      if arguments.size != 3: throw "INVALID_ARGUMENT"
      expected/int := arguments[0]
      operation/int := arguments[1]
      if not [api.CENTRAL-READ, api.CENTRAL-WRITE, api.CENTRAL-SERVICES,
              api.CENTRAL-CHARACTERISTICS, api.CENTRAL-DESCRIPTORS, api.CENTRAL-SUBSCRIBE,
              api.CENTRAL-WRITE-COMMAND, api.CENTRAL-INCLUDED, api.CENTRAL-READ-BY-UUID,
              api.CENTRAL-READ-MULTIPLE].contains operation:
        throw "INVALID_ARGUMENT"
      client_.check-database-revision expected
      result := invoke operation arguments[2] --revision=expected
      client_.check-database-revision expected
      return result
    if index == api.CENTRAL-MONITOR:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      if subscriptions_.size == 8: throw "ATT_SUBSCRIPTION_LIMIT"
      token := ++next-subscription_
      subscriptions_[token] = Subscription_ client_ 0 0 true 8 --monitor-changes
      return token
    if index == api.CENTRAL-SUBSCRIBE:
      if arguments.size != 4: throw "INVALID_ARGUMENT"
      handle/int := arguments[0]
      cccd/int := arguments[1]
      indications/bool := arguments[2]
      limit/int := arguments[3]
      if not 1 <= handle < cccd <= 0xffff or not 1 <= limit <= 32: throw "INVALID_ARGUMENT"
      if subscriptions_.size == 8: throw "ATT_SUBSCRIPTION_LIMIT"
      token := ++next-subscription_
      subscriptions_[token] = Subscription_ client_ handle cccd indications limit --revision=revision
      return token
    if index == api.CENTRAL-SUBSCRIPTION-READY or index == api.CENTRAL-SUBSCRIPTION-NEXT or index == api.CENTRAL-UNSUBSCRIBE:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      subscription/Subscription_? := subscriptions_.get arguments[0]
      if not subscription: throw "ATT_SUBSCRIPTION_CLOSED"
      if index == api.CENTRAL-UNSUBSCRIBE:
        try:
          subscription.stop
        finally:
          if subscription.ended: subscriptions_.remove arguments[0]
        return null
      if index == api.CENTRAL-SUBSCRIPTION-READY:
        subscription.ready
        return null
      return subscription.receive
    if index == api.CENTRAL-READ:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      return client_.read-long arguments[0] --database-revision=revision
    if index == api.CENTRAL-WRITE:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      value/ByteArray := arguments[1]
      if value.size > 512: throw "INVALID_ARGUMENT"
      if value.size <= client_.mtu - 3: client_.write arguments[0] value --database-revision=revision
      else: client_.write-long arguments[0] value --database-revision=revision
      return null
    if index == api.CENTRAL-WRITE-COMMAND:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      client_.write-command arguments[0] arguments[1] --database-revision=revision
      return null
    if index == api.CENTRAL-SERVICES:
      if not arguments.is-empty: throw "INVALID_ARGUMENT"
      return (gatt.services client_).map: | s/gatt.Service | [s.start, s.end, s.uuid.copy]
    if index == api.CENTRAL-CHARACTERISTICS:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      return (gatt.characteristics client_ (gatt.Service arguments[0] arguments[1] #[])).map: | c/gatt.Characteristic |
        [c.declaration, c.handle, c.properties, c.uuid.copy, c.end]
    if index == api.CENTRAL-INCLUDED:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      return (gatt.included-services client_ (gatt.Service arguments[0] arguments[1] #[])).map: | i/gatt.IncludedService |
        [i.handle, i.start, i.end, i.uuid.copy]
    if index == api.CENTRAL-READ-BY-UUID:
      if arguments.size != 3 or arguments[0] is not ByteArray: throw "INVALID_ARGUMENT"
      return gatt.read-by-uuid client_ arguments[0] --start=arguments[1] --end=arguments[2]
    if index == api.CENTRAL-READ-MULTIPLE:
      if arguments.size != 2 or arguments[0] is not List or arguments[0].size > 32: throw "INVALID_ARGUMENT"
      return gatt.read-multiple client_ arguments[0] --variable=arguments[1]
    if index == api.CENTRAL-DESCRIPTORS:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      c := gatt.Characteristic 0 arguments[0] 0 #[]
      c.end = arguments[1]
      return (gatt.descriptors client_ c).map: | d/gatt.Descriptor | [d.handle, d.uuid.copy]
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

// A provider task holds the cheap ATT subscription block for its RPC lifetime.
// Values stay in ATT's bounded managed queue; RPC does not add a second queue.
class Subscription_:
  ready_/monitor.Latch ::= monitor.Latch
  stop_/monitor.Latch ::= monitor.Latch
  ended_/monitor.Latch ::= monitor.Latch
  worker_/Task? := null
  stream_/att.Subscription? := null
  error_ := null

  constructor client/att.Client handle/int cccd/int indications/bool limit/int --monitor-changes/bool=false --revision/int?=null:
    worker_ = task --background::
      try:
        error_ = catch:
          if monitor-changes:
            gatt.with-service-changed client:
              ready_.set true
              stop_.get
          else:
            client.subscribe handle --cccd=cccd --indications=indications --queue-limit=limit
                --database-revision=revision: | stream/att.Subscription |
              stream_ = stream
              ready_.set true
              stop_.get
      finally:
        critical-do --no-respect-deadline:
          if not ready_.has-value: ready_.set (error_ or "ATT_SUBSCRIPTION_CLOSED") --exception
          ended_.set true

  ready -> none: ready_.get
  ended -> bool: return ended_.has-value
  receive -> ByteArray:
    ready
    if not stream_: throw "INVALID_ARGUMENT"
    // ATT returns an owned payload view; RPC copies slices into the message.
    return stream_.receive

  stop -> none:
    if not stop_.has-value: stop_.set true
    wait-ended
    if error_: throw error_

  cancel -> none:
    if worker_: worker_.cancel
  wait-ended -> none:
    with-timeout timeouts.WORKER: ended_.get
