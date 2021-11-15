// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

assert_ [cond]:
  if not cond.call: rethrow "ASSERTION_FAILED" (encode_error_ "ASSERTION_FAILED" "")
