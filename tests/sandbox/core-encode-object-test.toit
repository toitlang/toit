// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The object encoder is only exposed for errors (encode_error), which the
// core library needs for uncaught exceptions.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    encode-object_ [1, "two", #[3]]

encode-object_ object:
  #primitive.core.encode-object
