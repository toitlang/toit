// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli show Ui
import cli.test show TestUi
import expect show *
import host.directory
import system

import ...tools.pkg.project
import ...tools.pkg.semantic-version

main:
  tmp-dir := directory.mkdtemp "/tmp/filelock-logger-test-"
  try:
    ui := TestUi --level=Ui.DEBUG-LEVEL
    config := ProjectConfiguration
        --project-root=tmp-dir
        --cwd=directory.cwd
        --sdk-version=(SemanticVersion.parse system.vm-sdk-version)
        --ui=ui
    project := Project config --empty-lock-file --ui=ui
    project.save

    project.clean

    expect (ui.stdout.contains "[filelock] : acquired lock")
    expect (ui.stdout.contains "[filelock] : released lock")
  finally:
    directory.rmdir --force --recursive tmp-dir
