// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import host.pipe show Stream
import io
import io show LITTLE-ENDIAN
import monitor show Semaphore

/**
Connection that dispatches the data of the given $Stream to two pipes.

If data is produced faster than it is consumed, then the data is buffered. There
  is no flow-control.

The given incoming $Stream should be the stdout of the C++ compiler. Data
  is framed with a 4-byte integer indicating the size of the frame. If the
  number is negative then the frame-data is sent to $compiler-to-fs. Otherwise
  it's destined for $compiler-to-parser.
*/
class MultiplexConnection:
  compiler-to-fs_         / MultiplexedReader_
  compiler-to-parser_     / MultiplexedReader_
  from-compiler_          / Stream
  buffered-from-compiler_ / io.Reader

  constructor from-compiler/Stream:
    from-compiler_ = from-compiler

    closed-count := 0
    close-check := ::
      closed-count++
      if closed-count == 2:
        from-compiler.close

    compiler-to-fs_ = MultiplexedReader_ --on-close=close-check
    compiler-to-parser_ = MultiplexedReader_ --on-close=close-check
    buffered-from-compiler_ = from-compiler_.in

  compiler-to-fs -> io.CloseableReader: return compiler-to-fs_
  compiler-to-parser -> io.CloseableReader: return compiler-to-parser_

  /**
  Starts reading from stdout pipe and dispatches to the two simple pipes.
  */
  start-dispatch:
    task::
      catch --trace:
        do-dispatch_

  do-dispatch_:
    try:
      while buffered-from-compiler_.try-ensure-buffered 4:
        frame-size-bytes := buffered-from-compiler_.read-bytes 4
        frame-size := LITTLE-ENDIAN.int32 frame-size-bytes 0
        to := compiler-to-parser_
        if frame-size < 0:
          frame-size = -frame-size
          to = compiler-to-fs_
        data := buffered-from-compiler_.read-bytes frame-size
        to.write_ data
    finally:
      close

  close:
    compiler-to-fs.close
    compiler-to-parser.close

/**
A $io.CloseableReader that is fed data throw the $write_ method.
*/
class MultiplexedReader_ extends io.CloseableReader:
  is-closed_ := false
  buffered_chunks_ /Deque := Deque
  sem_ / Semaphore := Semaphore
  close-callback_ / Lambda

  constructor --on-close/Lambda:
    close-callback_ = on-close

  read_ -> ByteArray?:
    sem_.down
    result := ?
    if buffered_chunks_.is-empty:
      result = null
    else:
      result = buffered_chunks_.first
      buffered_chunks_.remove-first
    return result

  close_:
    if not is-closed_:
      is-closed_ = true
      sem_.up
      close-callback_.call

  write_ data/ByteArray:
    buffered_chunks_.add data
    sem_.up
