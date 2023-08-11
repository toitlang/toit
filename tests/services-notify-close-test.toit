// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services
import expect show *

main:
  4.repeat:
    clients := it + 1
    [1, 2, 4, 8, 16].do: | count/int |
      test clients count --eager-close
      test clients count --no-eager-close
      critical-do: test clients count --eager-close
      critical-do: test clients count --no-eager-close

test clients/int count/int --eager-close/bool:
  state := State
  provider := ResourceServiceProvider state
  provider.install

  proxies := []
  clients.repeat:
    client := ResourceServiceClient
    client.open
    count.repeat: proxies.add (ResourceProxy client)

  provider.shutdown (clients * count) --eager-close=eager-close
  provider.uninstall --wait

  proxies.do: | proxy/ResourceProxy |
    expect-equals 1 proxy.notifications
  expect-equals 0 state.usage

interface ResourceService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="249626b6-aff4-4ea9-bf6b-f72d80b71597"
      --major=1
      --minor=2

  new -> int
  static NEW-INDEX ::= 0

class ResourceServiceClient extends services.ServiceClient implements ResourceService:
  handles/int := 0

  static SELECTOR ::= ResourceService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  new -> int:
    return invoke_ ResourceService.NEW-INDEX null

class ResourceProxy extends services.ServiceResourceProxy:
  static NOTIFICATION-HAS-CLOSED ::= 1234
  static NOTIFICATION-SHOULD-CLOSE ::= 2345
  notifications/int := 0

  constructor client/ResourceServiceClient:
    super client client.new
    client.handles++

  on-notified_ notification/any -> none:
    notifications++
    if notification == NOTIFICATION-SHOULD-CLOSE:
      close
    else:
      expect-equals NOTIFICATION-HAS-CLOSED notification
      close-handle_

  close-handle_ -> int?:
    handle := super
    client := client_ as ResourceServiceClient
    if client.handles-- == 1:
      task::
        // Wait a little while before closing down
        // the client, so we get the individual handle
        // closing code exercised.
        sleep --ms=50
        client.close
    return handle

// ------------------------------------------------------------------

class ResourceServiceProvider extends services.ServiceProvider
    implements ResourceService services.ServiceHandler:
  state_/State

  constructor .state_:
    super "resource" --major=1 --minor=2 --patch=5
    provides ResourceService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ResourceService.NEW-INDEX:
      return new client
    unreachable

  new -> int:
    unreachable  // TODO(kasper): Nasty.

  new client/int -> services.ServiceResource:
    state_.up
    return Resource this client state_

  shutdown count/int --eager-close/bool -> none:
    notifications := 0

    critical-do: resources-do:
      if eager-close:
        it.notify_ ResourceProxy.NOTIFICATION-HAS-CLOSED --close
      else:
        it.notify_ ResourceProxy.NOTIFICATION-SHOULD-CLOSE
      notifications++
    expect-equals count notifications

class Resource extends services.ServiceResource:
  state_/State
  constructor provider/ResourceServiceProvider client/int .state_:
    super provider client --notifiable

  on-closed -> none:
    critical-do: state_.down

monitor State:
  usage_/int := 0

  usage -> int: return usage_
  up -> none: usage_++
  down -> none: usage_--
