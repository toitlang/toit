// Copyright (C) 2026 Toit contributors.

// Host versions of perfbench's task and RPC benchmarks, for instruction
// counts under callgrind: `taskbench BENCH N` runs N iterations of one
// benchmark (N = 0 gives the fixed cost to subtract).
//   rpc:   N service calls `add` to a provider in a spawned process
//   yield: N yields of a single task
//   tasks: N channel ping-pongs between two tasks
//   echo:  N service calls `echo` with perfbench's 15-element payload

import monitor
import .echo-service

// Uninstalls itself (when the client has closed) after `limit` calls, so
// the spawned process and then the VM terminate.
class CountingProvider extends EchoServiceProvider:
  limit/int
  constructor .limit:

  handle index/int arguments/any --gid/int --client/int -> any:
    result := super index arguments --gid=gid --client=client
    if calls == limit: task:: uninstall --wait
    return result

main args:
  name := args[0]
  n := int.parse args[1]
  if name == "rpc" or name == "echo":
    spawn::
      provider := CountingProvider n + 1
      provider.install
    sleep --ms=50
    client := EchoServiceClient
    client.open --timeout=(Duration --s=10)
    // Warm up (lazy initialization of the RPC path).
    s := client.add 1 2
    payload := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, "one", "two", "three", "four", "five"]
    start := Time.monotonic-us
    if name == "rpc":
      n.repeat: s = client.add s it
    else:
      n.repeat: client.echo payload
    print "$name $n $(Time.monotonic-us - start) us"
    client.close
    return
  if name == "yield":
    yield
    start := Time.monotonic-us
    n.repeat: yield
    print "$name $n $(Time.monotonic-us - start) us"
    return
  if name == "tasks":
    to := monitor.Channel 1
    back := monitor.Channel 1
    task::
      (n + 1).repeat: back.send to.receive
    to.send -1
    back.receive
    start := Time.monotonic-us
    n.repeat:
      to.send it
      back.receive
    print "$name $n $(Time.monotonic-us - start) us"
    return
  throw "unknown benchmark $name"
