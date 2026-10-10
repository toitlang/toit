// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor show ResourceState_
import system

main:
  if system.platform != system.PLATFORM-LINUX and system.platform != system.PLATFORM-MACOS:
    return
  group := init_
  // Validate primitive inputs directly, independent of the host package API.
  ["", "a\u0000b", ("x" * 200), ("é" * 100)].do: | path |
    expect-throw "INVALID_ARGUMENT": listen_ group path 10
    expect-throw "INVALID_ARGUMENT": connect_ group path
  expect-throw "INVALID_ARGUMENT": listen_ group "/unused" -1
  directory := (mkdtemp_ "/tmp/toit-unix-").to-string
  path := "$directory/socket"
  listener := null
  client := null
  accepted := null
  client-state := null
  accepted-state := null
  try:
    expect-not-null (catch: connect_ group path)
    listener = listen_ group path 1
    expect-equals path (path_ listener false)
    expect-null (accept_ group listener)
    expect-not-null (catch: listen_ group path 1)
    client = connect_ group path
    client-state = ResourceState_ group client
    client-state.wait-for-state 2 | 8
    expect-equals 0 (error-number_ client)
    expect-equals path (path_ client true)
    expect-null (path_ client false)
    accepted = accept_ group listener
    expect-not-null accepted
    accepted-state = ResourceState_ group accepted
    expect-equals path (path_ accepted false)
    expect-null (path_ accepted true)
    expect-equals -1 (read_ group accepted)
    expect-throw "OUT_OF_BOUNDS": write_ group client "hello" -1 2
    expect-throw "OUT_OF_BOUNDS": write_ group client "hello" 0 6
    expect-equals 0 (write_ group client "" 0 0)
    expect-equals 5 (write_ group client "hello" 0 5)
    accepted-state.wait-for-state 1 | 8
    expect-equals "hello" (read_ group accepted).to-string
    accepted-state.clear-state 1
    close-write_ group client
    accepted-state.wait-for-state 1 | 4 | 8
    expect-null (read_ group accepted)
    // Half-close leaves the opposite direction usable.
    expect-equals 5 (write_ group accepted "reply" 0 5)
    client-state.wait-for-state 1 | 8
    expect-equals "reply" (read_ group client).to-string
    // Fill the kernel buffer and verify the native would-block result.
    data := ByteArray (64 * 1024)
    total := 0
    while true:
      count := write_ group accepted data 0 data.size
      if count == -1: break
      expect (count > 0)
      total += count
      expect (total < 64 * 1024 * 1024)
    expect (total > 0)
  finally:
    if client-state: client-state.dispose
    if accepted-state: accepted-state.dispose
    if accepted: close_ group accepted
    if client: close_ group client
    if listener: close_ group listener
    // Close does not unlink the pathname.
    if listener: unlink_ path
    rmdir_ directory

init_:
  #primitive.unix-socket.init
connect_ group path:
  #primitive.unix-socket.connect
listen_ group path backlog:
  #primitive.unix-socket.listen
accept_ group resource:
  #primitive.unix-socket.accept
read_ group resource:
  #primitive.unix-socket.read
write_ group resource data from to:
  #primitive.unix-socket.write
close-write_ group resource:
  #primitive.unix-socket.close-write
close_ group resource:
  #primitive.unix-socket.close
path_ resource peer:
  #primitive.unix-socket.path
error-number_ resource:
  #primitive.unix-socket.error-number
mkdtemp_ prefix:
  #primitive.file.mkdtemp
unlink_ path:
  #primitive.file.unlink
rmdir_ path:
  #primitive.file.rmdir
