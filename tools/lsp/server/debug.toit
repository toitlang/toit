// Copyright (C) 2021 Toitware ApS. All rights reserved.

/**
This library is used for debugging an issue (#4589) we have on mac builds.
Once that issue is solved we can remove this library and all references to it.
*/

import host.os

should_print_debug_info := os.env.contains "TOIT_DEBUG_COMPLETION"

print_debug msg/string:
  if should_print_debug_info: print_on_stderr_ "$Time.now.ms_since_epoch: $msg"
