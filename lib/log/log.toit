// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .level
import .target

export *

/**
Logging support.
*/

/** The default logger. */
default -> Logger:
  return default_

/** Sets the $logger as the default. */
set_default logger/Logger:
  default_ = logger

default_ := Logger DEBUG_LEVEL DefaultTarget

/**
Logs the $message at the given $level to the default logger.

Includes the given $tags and $exception in the log message.
*/
log level/int message/string --tags/Map?=null --trace/ByteArray?=null -> none:
  default_.log level message --tags=tags --trace=trace

/**
Logs the $message to the default logger at debug level ($DEBUG_LEVEL).

Includes the given $tags and $exception in the log message.
*/
debug message/string --tags/Map?=null --trace/ByteArray?=null-> none:
  default_.log DEBUG_LEVEL message --tags=tags --trace=trace

/**
Logs the $message to the default logger at info level ($INFO_LEVEL).

Includes the given $tags and $exception in the log message.
*/
info message/string --tags/Map?=null --trace/ByteArray?=null-> none:
  default_.log INFO_LEVEL message --tags=tags --trace=trace

/**
Logs the $message to the default logger at warning level ($WARN_LEVEL).

Includes the given $tags and $exception in the log message.
*/
warn message/string --tags/Map?=null --trace/ByteArray?=null-> none:
  default_.log WARN_LEVEL message --tags=tags --trace=trace

/**
Logs the $message to the default logger at error level ($ERROR_LEVEL).

Includes the given $tags and $exception in the log message.
*/
error message/string --tags/Map?=null --trace/ByteArray?=null-> none:
  default_.log ERROR_LEVEL message --tags=tags --trace=trace

/**
Logs the $message to the default logger at fatal level ($FATAL_LEVEL).

Includes the given $tags and $exception in the log message.
*/
fatal message/string --tags/Map?=null --trace/ByteArray?=null-> none:
  default_.log FATAL_LEVEL message --tags=tags --trace=trace

/**
A logger that logs messages to a given target.

A logger can have a name set in the constructor
  ($Logger level_ target_ name). Sub-loggers with sub-names are created with
  $with_name.
A logger can be associated with a set of tags that are added to all logged
  messages (see $with_tag).
*/
class Logger:
  target_/Target
  level_/int

  names_/List?
  keys_/List? ::= null
  values_/List? ::= null

  /**
  Constructs a logger with the given $level_ and $target_.

  All log messages below the $level_ are discarded.

  The log is associated with the $name.
  */
  constructor .level_/int .target_/Target --name/string?=null:
    names_ = name ? [name] : null

  constructor.internal_ parent/Logger --name/string?=null --level/int?=null --tags/Map?=null:
    level_ = level ? (max level parent.level_) : parent.level_
    target_ = parent.target_
    parent_names ::= parent.names_
    if name:
      if parent_names:
        names_ = parent_names.copy
        names_.add name
      else:
        names_ = [name]
    else:
      names_ = parent_names
    merge_tags_ tags parent.keys_ parent.values_: | keys values |
      keys_ = keys
      values_ = values

  /** Adds the $name to a copy of this logger. */
  with_name name/string -> Logger:
    return Logger.internal_ this --name=name

  /**
  Adds the $level to a copy of this logger.

  The level can only be increased to log fewer messages.
  */
  with_level level/int -> Logger:
    return Logger.internal_ this --level=level

  /**
  Adds the tag composed by the $key and the $value to a copy of this logger.
  */
  with_tag key/string value -> Logger:
    return Logger.internal_ this --tags={key: value}

  /**
  Calls the $block if $level is enabled by the logger. Can be useful to
    avoid heavy computations at disabled log levels.

  The $block is called with the logger as argument.
  */
  with_level level/int [block] -> none:
    if level < level_: return
    block.call this

  /**
  Logs the $message at the given $level.

  Includes the given $tags and $exception in the log message.
  */
  log level/int message/string --tags/Map?=null --trace/ByteArray?=null -> none:
    if level < level_: return
    log_ level message --tags=tags --trace=trace
    if level == FATAL_LEVEL: throw "FATAL"

  /**
  Logs the $message at debug level ($DEBUG_LEVEL).

  Includes the given $tags and $exception in the log message.
  */
  debug message/string --tags/Map?=null --trace/ByteArray?=null -> none:
    log DEBUG_LEVEL message --tags=tags --trace=trace

  /**
  Logs the $message at info level ($INFO_LEVEL).

  Includes the given $tags and $exception in the log message.
  */
  info message/string --tags/Map?=null --trace/ByteArray?=null -> none:
    log INFO_LEVEL message --tags=tags --trace=trace

  /**
  Logs the $message at warning level ($WARN_LEVEL).

  Includes the given $tags and $exception in the log message.
  */
  warn message/string --tags/Map?=null --trace/ByteArray?=null -> none:
    log WARN_LEVEL message --tags=tags --trace=trace

  /**
  Logs the $message at error level ($ERROR_LEVEL).

  Includes the given $tags and $exception in the log message.
  */
  error message/string --tags/Map?=null --trace/ByteArray?=null -> none:
    log ERROR_LEVEL message --tags=tags --trace=trace

  /**
  Logs the $message at fatal level ($FATAL_LEVEL).

  Includes the given $tags and $exception in the log message.
  */
  fatal message/string --tags/Map?=null --trace/ByteArray?=null -> none:
    log FATAL_LEVEL message --tags=tags --trace=trace

  log_ level/int message/string --tags/Map?=null --trace/ByteArray?=null:
    merge_tags_ tags keys_ values_: | keys/List? values/List? |
      target_.log level message names_ keys values trace

  /**
  Merge any tags provided in the $tags map with the preexisting $keys
    and $values lists.

  The new tags in $tags take override any existing key/value pairs
    represented in the lists.
  */
  static merge_tags_ tags/Map? keys/List? values/List? [block] -> any:
    if not tags or tags.is_empty: return block.call keys values
    merged_keys := keys ? keys.copy : []
    merged_values := values ? values.copy : []
    tags.do: | key value |
      // We assume that the number of keys is typically less than a
      // handful, so we optimize for memory usage by finding the existing
      // index through a linear search instead of using an extra map.
      index := keys ? keys.index_of key : -1
      if index >= 0:
        merged_values[index] = value.stringify
      else:
        merged_keys.add key
        merged_values.add value.stringify
    return block.call merged_keys merged_values
