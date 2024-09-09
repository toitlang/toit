# Copyright (C) 2024 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

param (
    [string]$Executable,   # First argument: the path to the executable.
    [string[]]$Args        # Rest of the arguments to pass to the executable.
)

# Check if the executable is provided.
if (-not $Executable) {
    Write-Error "No executable provided!"
    exit 1
}

# Execute the provided executable with the remaining arguments.
$process = Start-Process -FilePath $Executable -ArgumentList $Args -NoNewWindow -Wait -PassThru

# Check the exit code of the process.
if ($process.ExitCode -eq 0) {
    Write-Error "Executable did not fail as expected!"
    exit 1  # Fail if the program didn't fail.
} else {
    Write-Output "Program failed as expected. Exit code: $($process.ExitCode)"
    exit 0  # Success, since the program failed.
}
