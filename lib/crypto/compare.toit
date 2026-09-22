// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Compares byte arrays using mbedTLS's constant-time content comparison.

Length is not secret: unequal lengths return false immediately, and runtime
  depends on the common length. Equal-length buffers are compared without a
  content-dependent early exit. Empty arrays compare equal. This does not hide
  scheduling, allocation, or timing outside this native comparison.
*/
constant-time-equals first/ByteArray second/ByteArray -> bool:
  #primitive.crypto.constant-time-equals
