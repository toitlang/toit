// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import .vm-smoke as vm
import .gpio-resource-rp2350 as resources
import .gpio-interrupt-rp2350 as interrupts

main:
  vm.main
  resources.main
  interrupts.main
