// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that FLAG-UNTRUSTED on an image is binding: the container manager
// starts containers from a flagged image with the untrusted policy, even
// if the start request asks for the trusted policy.

import expect show *
import system.api.containers show ContainerService
import ...system.containers show Container

TRUSTED ::= ContainerService.POLICY-TRUSTED
UNTRUSTED ::= ContainerService.POLICY-UNTRUSTED

main:
  // Flagged images always run untrusted.
  expect-equals UNTRUSTED (Container.policy-for_ null --image-untrusted)
  expect-equals UNTRUSTED (Container.policy-for_ TRUSTED --image-untrusted)
  expect-equals UNTRUSTED (Container.policy-for_ UNTRUSTED --image-untrusted)

  // Images without the flag run with the requested policy.
  expect-equals TRUSTED (Container.policy-for_ null --no-image-untrusted)
  expect-equals TRUSTED (Container.policy-for_ TRUSTED --no-image-untrusted)
  expect-equals UNTRUSTED (Container.policy-for_ UNTRUSTED --no-image-untrusted)

  // Invalid policies are rejected for both.
  expect-throw "INVALID_ARGUMENT": Container.policy-for_ 0 --image-untrusted
  expect-throw "INVALID_ARGUMENT": Container.policy-for_ 0 --no-image-untrusted
  print "flag-untrusted-test OK"
