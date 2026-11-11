// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .sandbox
import crypto.sha256

// The crypto module is not in the measured allowed set. Through the library,
// the resource group (core.get-generic-resource-group, denied) fails first.
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    expect-throw "PERMISSION_DENIED": sha256.sha256 "data"
    sha-start_ null 256

sha-start_ group bits/int:
  #primitive.crypto.sha-start
