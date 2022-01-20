// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show BufferedReader Reader CloseableReader
import writer show Writer
import binary show LITTLE_ENDIAN
import host.pipe show OpenPipe
import monitor show Semaphore

/**
Connection that dispatches the data of the given $OpenPipe to two pipes.
The $compiler_to_fs and $compiler_to_parser $SimplePipe should be used as a
  normal $CloseableReader.

If data is produced faster than it is consumed, then the data is buffered. There
  is now flow-control.

The given incoming $OpenPipe should be the stdout of the C++ compiler. Data
  is framed with a 4-byte integer indicating the size of the frame. If the
  number is negative then the frame-data is sent to $compiler_to_fs. Otherwise
  it's destined for $compiler_to_parser.
*/
class MultiplexConnection:
  compiler_to_fs          / SimplePipe
  compiler_to_parser      / SimplePipe
  from_compiler_          / OpenPipe
  buffered_from_compiler_ / BufferedReader

  constructor .from_compiler_:
    closed_count := 0
    close_check := ::
      closed_count++
      if closed_count == 2:
        from_compiler_.close

    compiler_to_fs = SimplePipe --on_close=close_check
    compiler_to_parser = SimplePipe --on_close=close_check
    buffered_from_compiler_ = BufferedReader from_compiler_

  /**
  Starts reading from stdout pipe and dispatches to the two simple pipes.
  */
  start_dispatch:
    task::
      catch --trace:
        do_dispatch_

  do_dispatch_:
    try:
      while buffered_from_compiler_.can_ensure 4:
        frame_size_bytes := buffered_from_compiler_.read_bytes 4
        frame_size := LITTLE_ENDIAN.int32 frame_size_bytes 0
        to := compiler_to_parser
        if frame_size < 0:
          frame_size = -frame_size
          to = compiler_to_fs
        data := buffered_from_compiler_.read_bytes frame_size
        to.write_ data
    finally:
      close

  close:
    compiler_to_fs.close
    compiler_to_parser.close

/**
A $CloseableReader that is fed data throw the $write_ method.
*/
class SimplePipe implements CloseableReader:
  is_closed_ := false
  buffered_ /Deque := Deque
  sem_ / Semaphore := Semaphore
  close_callback_ / Lambda

  constructor --on_close/Lambda:
    close_callback_ = on_close

  read -> ByteArray?:
    sem_.down
    result := ?
    if buffered_.is_empty:
      result = null
    else:
      result = buffered_.first
      buffered_.remove_first
    return result

  close:
    if not is_closed_:
      is_closed_ = true
      sem_.up
      close_callback_.call

  write_ data/ByteArray:
    buffered_.add data
    sem_.up

