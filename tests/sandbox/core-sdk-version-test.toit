// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import .sandbox

// The SDK version queries are not readable (like vm_sdk_info); the platform,
// the architecture and the word size are.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    expect system.platform is string
    expect system.architecture is string
    expect (system.BITS-PER-WORD == 32 or system.BITS-PER-WORD == 64)
    expect-throw "PERMISSION_DENIED": system.vm-sdk-version
    expect-throw "PERMISSION_DENIED": system.vm-sdk-model
    expect-throw "PERMISSION_DENIED": system.app-sdk-info
    system.app-sdk-version
