// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

assert_ [condition]:
  if condition.call: return
  rethrow ASSERTION-FAILED-ERROR (encode-error_ ASSERTION-FAILED-ERROR "")
