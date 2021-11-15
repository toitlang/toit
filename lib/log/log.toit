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

Includes the given $tags in the log message.
*/
log level message --tags=null -> none:
  default_.log level message --tags=tags

/**
Logs the $message to the default logger at debug level ($DEBUG_LEVEL).

Includes the given $tags in the log message.
*/
debug message --tags=null -> none:
  default_.log DEBUG_LEVEL message --tags=tags

/**
Logs the $message to the default logger at info level ($INFO_LEVEL).

Includes the given $tags in the log message.
*/
info message --tags=null -> none:
  default_.log INFO_LEVEL message --tags=tags

/**
Logs the $message to the default logger at warning level ($WARN_LEVEL).

Includes the given $tags in the log message.
*/
warn message --tags=null -> none:
  default_.log WARN_LEVEL message --tags=tags

/**
Logs the $message to the default logger at error level ($ERROR_LEVEL).

Includes the given $tags in the log message.
*/
error message --tags=null -> none:
  default_.log ERROR_LEVEL message --tags=tags

/**
Logs the $message to the default logger at fatal level ($FATAL_LEVEL).

Includes the given $tags in the log message.
*/
fatal message --tags=null -> none:
  default_.log FATAL_LEVEL message --tags=tags

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
  tags_/Map
  names_/List?

  /**
  Constructs a logger with the given $level_ and $target_.

  All log messages below the $level_ are discarded.

  The log is associated with the $name.
  */
  constructor .level_/int .target_/Target --name=null:
    names_ = name ? [name] : []
    tags_ = {:}

  constructor.internal_ parent/Logger --name/string?=null --level/int?=null --tags/Map?=null:
    level_ = level ? (max level parent.level_) : parent.level_
    target_ = parent.target_
    if tags and not tags.is_empty:
      tags_ = {:}
      parent.tags_.do: | k v | tags_[k] = v
      tags.do: | k v | tags_[k] = v
    else:
      tags_ = parent.tags_
    if name:
      names_ = parent.names_.copy
      names_.add name
    else:
      names_ = parent.names_

  /** Adds the $name to a copy of this logger. */
  with_name name -> Logger:
    return Logger.internal_ this --name=name

  /**
  Adds the $level to a copy of this logger.

  The level can only be increased to log fewer messages.
  */
  with_level level -> Logger:
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

  Includes the given $tags in the log message.
  */
  log level/int message/string --tags/Map?=null -> none:
    if level < level_: return

    tags_for_this_message/Map := ?
    if tags and not tags.is_empty:
      if not tags_.is_empty:
        tags_for_this_message = {:}
        tags_.do: | k v | tags_for_this_message[k] = v
        tags.do: | k v | tags_for_this_message[k] = v
      else:
        tags_for_this_message = tags
    else:
      tags_for_this_message = tags_

    target_.log names_ level message tags_for_this_message
    if level == FATAL_LEVEL: throw "FATAL"

  /**
  Logs the $message at debug level ($DEBUG_LEVEL).

  Includes the given $tags in the log message.
  */
  debug message/string --tags/Map?=null -> none:
    log DEBUG_LEVEL message --tags=tags

  /**
  Logs the $message at info level ($INFO_LEVEL).

  Includes the given $tags in the log message.
  */
  info message/string --tags/Map?=null -> none:
    log INFO_LEVEL message --tags=tags

  /**
  Logs the $message at warning level ($WARN_LEVEL).

  Includes the given $tags in the log message.
  */
  warn message/string --tags/Map?=null -> none:
    log WARN_LEVEL message --tags=tags

  /**
  Logs the $message at error level ($ERROR_LEVEL).

  Includes the given $tags in the log message.
  */
  error message/string --tags/Map?=null -> none:
    log ERROR_LEVEL message --tags=tags

  /**
  Logs the $message at fatal level ($FATAL_LEVEL).

  Includes the given $tags in the log message.
  */
  fatal message/string --tags/Map?=null -> none:
    log FATAL_LEVEL message --tags=tags
