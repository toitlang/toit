// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .level
import .target

export *

/**
Logging support.

Each application has a default logger, $default, that is global to the
  application. By default it is set to log all messages at $DEBUG-LEVEL.

Messages on the default logger are created by calling $log, $debug,
  $info, $warn, $error or $fatal. The same functions exist as
  methods on the $Logger class as well.

Instead of creating strings that contain context relevant information,
  it is possible to add tags to the log message. Tags are key/value pairs
  that are added to the log message. For example:

```
import log

main:
  log.info "Hello world" --tags={"name": "world"}
```

The default logger can be set with $set-default. For example:
```
import log

main:
  log.set-default (log.default.with-level log.INFO_LEVEL)
```

It is common to create a logger for parts of a program. In that case,
  use `.with --name=<part-name>` to create a sub-logger. Often, the
  class does this in its constructor:

```
import log

class Connectivity:
  logger_/log.Logger

  constructor --logger/log.Logger=(log.default.with-name "connectivity"):
    logger_ = logger
```
*/

/** The default logger. */
default -> Logger:
  return default_

/** Sets the $logger as the default. */
set-default logger/Logger:
  default_ = logger

default_ := Logger DEBUG-LEVEL DefaultTarget

/**
Logs the $message at the given $level to the default logger.

Includes the given $tags in the log message.
*/
log level/int message/string --tags/Map?=null -> none:
  default_.log level message --tags=tags

/**
Logs the $message to the default logger at debug level ($DEBUG-LEVEL).

Includes the given $tags in the log message.
*/
debug message/string --tags/Map?=null -> none:
  default_.log DEBUG-LEVEL message --tags=tags

/**
Logs the $message to the default logger at info level ($INFO-LEVEL).

Includes the given $tags in the log message.
*/
info message/string --tags/Map?=null -> none:
  default_.log INFO-LEVEL message --tags=tags

/**
Logs the $message to the default logger at warning level ($WARN-LEVEL).

Includes the given $tags in the log message.
*/
warn message/string --tags/Map?=null -> none:
  default_.log WARN-LEVEL message --tags=tags

/**
Logs the $message to the default logger at error level ($ERROR-LEVEL).

Includes the given $tags in the log message.
*/
error message/string --tags/Map?=null -> none:
  default_.log ERROR-LEVEL message --tags=tags

/**
Logs the $message to the default logger at fatal level ($FATAL-LEVEL).

Includes the given $tags in the log message.
*/
fatal message/string --tags/Map?=null -> none:
  default_.log FATAL-LEVEL message --tags=tags

/**
A logger that logs messages to a given target.

A logger can have a name set in the constructor
  ($Logger level_ target_ name). Sub-loggers with sub-names are created with
  $with-name.
A logger can be associated with a set of tags that are added to all logged
  messages (see $with-tag).
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
    parent-names ::= parent.names_
    if name:
      if parent-names:
        names_ = parent-names.copy
        names_.add name
      else:
        names_ = [name]
    else:
      names_ = parent-names
    merge-tags_ tags parent.keys_ parent.values_: | keys values |
      keys_ = keys
      values_ = values

  /** Adds the $name to a copy of this logger. */
  with-name name/string -> Logger:
    return Logger.internal_ this --name=name

  /**
  Adds the $level to a copy of this logger.

  The level can only be increased to log fewer messages.
  */
  with-level level/int -> Logger:
    return Logger.internal_ this --level=level

  /**
  Adds the tag composed by the $key and the $value to a copy of this logger.
  */
  with-tag key/string value -> Logger:
    return Logger.internal_ this --tags={key: value}

  /**
  Calls the $block if $level is enabled by the logger. Can be useful to
    avoid heavy computations at disabled log levels.

  The $block is called with the logger as argument.
  */
  with-level level/int [block] -> none:
    if level < level_: return
    block.call this

  /**
  Logs the $message at the given $level.

  Includes the given $tags in the log message.
  */
  log level/int message/string --tags/Map?=null -> none:
    if level < level_: return
    merge-tags_ tags keys_ values_: | keys/List? values/List? |
      target_.log level message names_ keys values
    if level == FATAL-LEVEL: throw "FATAL"

  /**
  Logs the $message at debug level ($DEBUG-LEVEL).

  Includes the given $tags in the log message.
  */
  debug message/string --tags/Map?=null -> none:
    log DEBUG-LEVEL message --tags=tags

  /**
  Logs the $message at info level ($INFO-LEVEL).

  Includes the given $tags in the log message.
  */
  info message/string --tags/Map?=null -> none:
    log INFO-LEVEL message --tags=tags

  /**
  Logs the $message at warning level ($WARN-LEVEL).

  Includes the given $tags in the log message.
  */
  warn message/string --tags/Map?=null -> none:
    log WARN-LEVEL message --tags=tags

  /**
  Logs the $message at error level ($ERROR-LEVEL).

  Includes the given $tags in the log message.
  */
  error message/string --tags/Map?=null -> none:
    log ERROR-LEVEL message --tags=tags

  /**
  Logs the $message at fatal level ($FATAL-LEVEL).

  Includes the given $tags in the log message.
  */
  fatal message/string --tags/Map?=null -> none:
    log FATAL-LEVEL message --tags=tags

  /**
  Merge any tags provided in the $tags map with the preexisting $keys
    and $values lists.

  The new tags in $tags take override any existing key/value pairs
    represented in the lists.
  */
  static merge-tags_ tags/Map? keys/List? values/List? [block] -> any:
    if not tags or tags.is-empty: return block.call keys values
    merged-keys := keys ? keys.copy : []
    merged-values := values ? values.copy : []
    tags.do: | key value |
      // We assume that the number of keys is typically less than a
      // handful, so we optimize for memory usage by finding the existing
      // index through a linear search instead of using an extra map.
      index := keys ? keys.index-of key : -1
      if index >= 0:
        merged-values[index] = value.stringify
      else:
        merged-keys.add key
        merged-values.add value.stringify
    return block.call merged-keys merged-values
