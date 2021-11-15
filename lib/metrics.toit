// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.ubjson as ubjson
import rpc
import statistics

/**
Support for recording metrics.

Recorded metrics are stored on the device and send to the toit cloud when a
  connection is available.
The metrics are stored in persistent memory, so they survive device deep
  sleeps, power offs, and other events that reset volatile memory.

The device may fail to record metrics if the persistent memory designated
  for metrics (metrics memory) is full. When the metrics memory is close to
  being full, then the device attempts to go online to offload the metrics
  and thus prevent lost metrics.
*/
// TODO(4222): When we have a tutorial for using the cloud API to get metrics, we should add a reference here.

/** Error string for invalid metric type. */
ERR_INVALID_METRIC_TYPE ::= "INVALID_METRIC_TYPE"
/** Error string for invalid metric level. */
ERR_INVALID_METRIC_LEVEL ::= "INVALID_METRIC_LEVEL"
/** Error string for invalid metric. */
ERR_INVALID_METRIC ::= "INVALID_METRIC"
/** Error string for repeat metric initialization. */
ERR_METRIC_ALREADY_INITIALIZED ::= "METRIC_ALREADY_INITIALIZED"

METRICS_TYPE_COUNTER_   ::= 1
METRICS_TYPE_GAUGE_     ::= 2
METRICS_TYPE_HISTOGRAM_ ::= 3

/** Debug level for metrics. */
METRICS_LEVEL_DEBUG ::= 0
/** Info level for metrics. */
METRICS_LEVEL_INFO ::= 5
/** Critical level for metrics. */
METRICS_LEVEL_CRITICAL ::= 10

is_valid_metrics_type_ type/int -> bool:
  return METRICS_TYPE_COUNTER_ <= type <= METRICS_TYPE_HISTOGRAM_

is_valid_metrics_level_ level/int -> bool:
  return level == METRICS_LEVEL_DEBUG or level == METRICS_LEVEL_INFO or level == METRICS_LEVEL_CRITICAL

class MetricIdentifier_:
  name/string ::= ?
  type/int ::= ?
  unsampled/bool ::= ?
  tags/Map?/*<string, string>*/ ::= ?
  level/int ::= ?

  constructor .name .type/int .tags/Map? .unsampled/bool .level/int:
    if not is_valid_metrics_type_ type:
      throw ERR_INVALID_METRIC_TYPE

    if not is_valid_metrics_level_ level:
      throw ERR_INVALID_METRIC_LEVEL

  serialize -> ByteArray:
    return ubjson.encode [name, type, tags, unsampled, level]

  constructor.deserialize bytes/ByteArray:
    m := ubjson.decode bytes
    if m is not List or m.size != 5:
      throw ERR_INVALID_METRIC
    name = m[0]
    if not is_valid_metrics_type_ m[1]:
      throw ERR_INVALID_METRIC_TYPE
    type = m[1]
    tags = m[2]
    unsampled = m[3]
    if not is_valid_metrics_level_ m[4]:
      throw ERR_INVALID_METRIC_LEVEL
    level = m[4]

RPC_METRICS_CREATE_   ::= 400
RPC_METRICS_UPDATE_   ::= 401
RPC_METRICS_DESTROY_  ::= 402
