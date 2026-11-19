// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A receiver that runs out of memory while decoding a message, and then
// dies, must not free the message's out-of-line data twice
// (message-receive-oom-input.toit). Its heap used to free the block a
// second time when it died (VmFinalizerNode::heap_dying ignored the
// cleared finalizer bit), after the message had freed it: glibc aborted
// the VM ("free(): double free detected in tcache 2").

import host.pipe
import expect show *

// Marked as compiler test so we get the toit.run path.
main args:
  toit-run := args[0]
  input := "tests/message-receive-oom-input.toit"
  process := pipe.fork
      --use-path
      --create-stdout
      toit-run
      [
        toit-run,
        input
      ]
  stdout := process.stdout.in.read-all.to-string
  exit-value := process.wait

  // The receiver's exception ends the program, with an exit code, not
  // with SIGABRT.
  expect-null (pipe.exit-signal exit-value)
  expect-not-equals 0 (pipe.exit-code exit-value)
  expect (stdout.contains "ALLOCATION_FAILED")
