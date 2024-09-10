#!/bin/bash

# Copyright (C) 2024 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Check if the executable is provided as the first argument.
if [ -z "$1" ]; then
  echo "No executable provided!"
  exit 1
fi

# Extract the executable and shift the arguments.
executable=$1
shift

# Execute the provided executable with the rest of the arguments.
"$executable" "$@"
exit_code=$?

# Check the exit code of the executable.
if [ $exit_code -eq 0 ]; then
  exit 0
else
  # Convert any non-zero exit code to 1.
  exit 1
fi
