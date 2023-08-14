// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// This example is the companion to https://github.com/toitlang/toit/discussions/869
// with the full working source code for the presented snippets.

import log
import monitor
import system.services show ServiceClient ServiceSelector ServiceResourceProxy
import system.services show ServiceProvider ServiceHandler ServiceResource

interface RandomService:
  static SELECTOR ::= ServiceSelector
      --uuid="dd9e5fd1-a5e9-464e-b2ef-92bf15ea02ca"
      --major=0
      --minor=1

  next limit/int -> int
  static NEXT_INDEX /int ::= 0

  create_die sides/int -> int
  static CREATE_DIE_INDEX /int ::= 1

  roll_die handle/int -> int
  static ROLL_DIE_INDEX /int ::= 2

main:
  spawn::
    service := RandomServiceProvider
    service.install
    service.uninstall --wait

  client := RandomServiceClient
  client.open
  10.repeat:
    print "random = $(client.next 100)"

  die := client.create_die 6
  10.repeat:
    print "die roll = $(die.roll)"
  sleep (Duration --s=10)
  die.close

class RandomServiceClient extends ServiceClient implements RandomService:
  static SELECTOR ::= RandomService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  next limit/int -> int:
    return invoke_ RandomService.NEXT_INDEX limit

  create_die sides/int -> DieProxy:
    handle := invoke_ RandomService.CREATE_DIE_INDEX sides
    proxy := DieProxy this handle
    return proxy

  roll_die handle/int -> int:
    return invoke_ RandomService.ROLL_DIE_INDEX handle

class RandomServiceProvider extends ServiceProvider
    implements ServiceHandler:
  constructor:
    super "test/random" --major=7 --minor=9
    provides RandomService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == RandomService.NEXT_INDEX: return next arguments
    if index == RandomService.CREATE_DIE_INDEX:
      resource := DieResource arguments this client
      return resource
    if index == RandomService.ROLL_DIE_INDEX:
      die := (resource client arguments) as DieResource
      return die.roll
    unreachable

  next limit/int -> int:
    log.info "got request for next random" --tags={"limit": limit}
    return random limit

class DieResource extends ServiceResource:
  sides_/int ::= ?
  task_ := null

  constructor .sides_ provider/ServiceProvider client/int:
    super provider client --notifiable
    task_ = task:: notify_periodically

  notify_periodically -> none:
    while not Task.current.is_canceled:
      sleep --ms=(random 500) + 500
      notify_ 87

  on_closed -> none:
    task_.cancel

  roll -> int:
    return random sides_

class DieProxy extends ServiceResourceProxy:
  pinged_ ::= monitor.Signal

  constructor client/ServiceClient handle/int:
    super client handle

  roll -> int:
    return (client_ as RandomServiceClient).roll_die handle_

  on_notified_ notification/any -> none:
    log.info "got notified" --tags={"notification": notification}
    pinged_.raise
