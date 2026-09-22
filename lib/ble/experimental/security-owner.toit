// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .central show Central Link
import .security-state show SecurityState

/** Owns security policy and SMP dispatch for one connection lifetime. */
interface Owner extends SecurityState:
  matches host/Central link/Link -> bool
  receive bytes/ByteArray -> none
  close -> none
