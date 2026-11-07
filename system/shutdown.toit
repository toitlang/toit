// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the top level directory.

import monitor
import system.services show ServiceProvider

/** Coordinates application and platform-service cleanup before a reboot. */
class ShutdownCoordinator:
  stop-containers_/Lambda
  phase-timeout_/Duration
  providers_/List := []
  rebooting_/bool := false

  constructor .stop-containers_ --phase-timeout/Duration=(Duration --s=5):
    phase-timeout_ = phase-timeout

  install provider/ServiceProvider -> none:
    if rebooting_: throw "System is shutting down"
    provider.install
    providers_.add provider

  reboot reset/Lambda -> none:
    if rebooting_: throw "System is shutting down"
    rebooting_ = true
    done := monitor.Latch
    // Killing the requesting container cancels its RPC task. Cleanup and
    // reset must therefore run in an independent, foreground task.
    task --background=false::
      attempt_ "containers": stop-containers_.call
      // Reverse installation order keeps dependencies alive during close.
      providers_.size.repeat: | i |
        provider/ServiceProvider := providers_[providers_.size - 1 - i]
        attempt_ provider.name: provider.uninstall --drain
      reset.call
      done.set true  // Only reached by a reset callback that returns (tests).
    done.get

  attempt_ name/string [action] -> none:
    error := catch:
      with-timeout phase-timeout_: action.call
    if error: print_ "[system] shutdown of $name failed: $error"
