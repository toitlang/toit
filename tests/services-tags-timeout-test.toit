// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test that connecting to a service with a tag does not fail if the
// service is only installed with a different tag.

import system.services show ServiceClient ServiceSelector ServiceResourceProxy
import system.services show ServiceProvider ServiceHandler ServiceResource

main args/List:
  2.repeat: | index |
    spawn::
      if index == 1:
        // Index 1 will not be there yet when we ask for it.
        sleep --ms=1000
      service := TagTimeoutTestServiceProvider index
      service.install
      service.uninstall --wait

  2.repeat: | index |
    task::
      client := TagTimeoutTestServiceClient index
      client.open --timeout=(Duration --s=30)
      client.close

interface TagTimeoutTestService:
  static SELECTOR ::= ServiceSelector
      --uuid="20e698fd-b89a-4964-a0c0-68e90ca37635"
      --major=1
      --minor=0

class TagTimeoutTestServiceClient extends ServiceClient implements TagTimeoutTestService:
  static SELECTOR ::= TagTimeoutTestService.SELECTOR

  constructor index/int:
    selective-selector := TagTimeoutTestService.SELECTOR.restrict.allow --tag="$index"
    assert: selective-selector.matches SELECTOR
    super selective-selector

class TagTimeoutTestServiceProvider extends ServiceProvider
    implements ServiceHandler:

  index/int

  constructor .index/int:
    super "tests/tag-timeout-test" --major=1 --minor=0
    provides TagTimeoutTestService.SELECTOR --handler=this --tags=["$index"]

  handle index/int arguments/any --gid/int --client/int -> any:
    unreachable
