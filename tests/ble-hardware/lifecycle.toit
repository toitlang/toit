// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.native
import encoding.hex
import host.directory
import system
import .adapter-policy as policy

// Exercise real controller ownership repeatedly in one VM. The pause allows
// asynchronous epoll removal and Linux controller teardown to complete.
main args/List:
  if not 2 <= args.size <= 3: throw "Usage: lifecycle.toit <adapter index> <expected address> [control]"
  control := args.size == 3 and args[2] == "control"
  if args.size == 3 and not control: throw "INVALID_ARGUMENT"
  adapter := int.parse args[0]
  expected := hex.decode (args[1].replace --all ":" "")
  if not 0 <= adapter < 0xffff or expected.size != 6: throw "INVALID_ARGUMENT"
  power-down adapter expected --control=control
  if not control: query adapter expected
  sleep --ms=1000
  baseline-fds := descriptor-count
  stats := system.process-stats --gc
  baseline := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
  maximum := baseline
  20.repeat: | cycle/int |
    // BlueZ may restore power when Linux registers the released controller.
    power-down adapter expected --control=control
    if not control: query adapter expected
    sleep --ms=1000
    fds := descriptor-count
    system.process-stats --gc stats
    live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    maximum = max maximum live
    print "LIFECYCLE cycle=$(cycle + 1) descriptors=$fds live=$live"
    if fds != baseline-fds: throw "DESCRIPTOR_COUNT_CHANGED"
    if live > baseline + 4096: throw "LIVE_MEMORY_GREW"
  print "LIFECYCLE_COMPLETE control=$control cycles=20 descriptors=$baseline-fds baseline=$baseline maximum=$maximum"

query adapter/int expected/ByteArray -> none:
  controller := hci.Controller (linux.LinuxTransport adapter)
  try:
    info := hci.initialize controller
    if info.address.reverse != expected: throw "HCI_WRONG_ADAPTER"
    print "address=$(hex.encode info.address.reverse) acl-length=$(info.acl-length) acl-count=$(info.acl-count)"
  finally:
    controller.close
    controller.wait-closed

descriptor-count -> int:
  entries := directory.DirectoryStream "/proc/self/fd"
  count := 0
  try:
    while entries.next: count++
  finally:
    entries.close
  return count

power-down adapter/int expected/ByteArray --control/bool=false -> none:
  if control: return
  policy.configure adapter expected "power-off": native.NativeTransport.management
