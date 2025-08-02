// Copyright (C) 2025 Toit contributors.
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

import system

import cli

import ..pkg
import ..project
import ..registry

import .utils_

class PkgCommand:
  ui/cli.Ui
  registries_/Registries? := null
  auto-sync_/bool

  constructor invocation/cli.Invocation:
    ui = invocation.cli.ui
    auto-sync_ = invocation[OPTION-AUTO-SYNC]

  error message/string:
    ui.abort message

  warning message/string:
    ui.emit --warning message

  registries -> Registries:
    if not registries_:
      registries_ = Registries --ui=ui --auto-sync=auto-sync_
    return registries_

class PkgProjectCommand extends PkgCommand:
  project/Project

  constructor invocation/cli.Invocation:
    config := project-configuration-from-cli invocation
    config.verify
    project = Project config --ui=invocation.cli.ui
    super invocation
