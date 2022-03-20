// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import core.message_manual_decoding_ show print_for_manually_decoding_

install_stack_trace_handler -> none:
  handler := StackTraceHandler
  set_system_message_handler_ SYSTEM_MIRROR_MESSAGE_ handler

class StackTraceHandler implements SystemMessageHandler_:
  on_message type/int gid/int pid/int arguments/any -> none:
    assert: type == SYSTEM_MIRROR_MESSAGE_
    // TODO(kasper): Automatically decode stack traces on non-embedded
    // platforms.
    print_for_manually_decoding_ arguments
