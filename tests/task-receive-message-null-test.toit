// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The library only receives a message when there is one, but a program can
// call the primitive directly at any time.

main:
  expect-not (task-has-messages)
  expect-null (task-receive-message)
  expect-null (task-receive-message)

task-has-messages -> bool:
  #primitive.core.task-has-messages

task-receive-message:
  #primitive.core.task-receive-message
