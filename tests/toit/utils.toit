// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.pipe
import system

class ToitExecutable:
  toit-run_/string
  toit-bin-src_/string
  sdk-dir_/string

  constructor args/List:
    toit-run_ = args[0]
    toit-bin-src_ = args[1]
    sdk-dir_ = args[2]

  backticks --with-test-sdk/bool=true args/List:
    full-command := [toit_run_, toit-bin-src_]
    if with-test-sdk:
      full-command += ["--sdk-dir", sdk-dir_]
    full-command += args
    result := pipe.backticks full-command
    if system.platform == system.PLATFORM-WINDOWS:
      return result.replace --all "\r\n" "\n"
    return result
