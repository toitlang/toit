// Copyright (C) 2024 Toitware ApS.
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

import .run-image-exit-codes

// The produced file has an MIT license.
BOOT-SH ::= """
#!/usr/bin/env bash

# Copyright (C) 2024 Toitware ApS.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the “Software”), to deal in
# the Software without restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
# Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# Directory structure:
#
#   <prefix>/boot.sh <- this file
#
#   The following two files are created if they don't exist yet.
#   <prefix>/current           (contains the string "ota0" or "ota1")
#   <prefix>/flash-registry
#
#   <prefix>/otaX/run-image
#   <prefix>/otaX/config.ubjson
#   <prefix>/otaX/bits.bin
#   <prefix>/otaX/startup-images    (optional)
#   <prefix>/otaX/bundled-images    (optional)
#   <prefix>/otaX/installed-images  (optional)
#
#   If an ota is validated, it also contains:
#     <prefix>/otaX/validated
#
#   Each firmware gets assigned a UUID at first boot, stored in:
#     <prefix>/otaX/uuid
#
#  We use <prefix>/scratch as temporary directory where a firmware can store the
#  updated firmware image.

# Compute the directory of this script and use it as the PREFIX.
PREFIX=\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Create the 'current' file, pointing to 'ota0' if it doesn't exist yet.
if [ ! -e "\$PREFIX/current" ]; then
  echo "ota0" > \$PREFIX/current
fi

for (( ; ; )); do
  current=\$(cat \$PREFIX/current)
  if [ "\$current" == "ota0" ]; then
    next="ota1"
  else
    next="ota0"
  fi
  echo "*******************************"
  echo "*** Running from \$current"
  echo "*******************************"

  export TOIT_CONFIG_DATA=\$(realpath \$PREFIX/\$current/config.ubjson)

  # Clear out the scratch directory.
  rm -rf \$PREFIX/scratch
  mkdir -p \$PREFIX/scratch

  # Run the image.
  export TOIT_FLASH_UUID_FILE=\$PREFIX/\$current/uuid
  export TOIT_FLASH_REGISTRY_FILE=\$PREFIX/flash-registry
  pushd \$PREFIX/\$current
  ./run-image \$PREFIX/\$current \$PREFIX/scratch &
  popd
  RUN_IMAGE_PID=\$!
  # Make sure to kill the run-image process if we are killed.
  trap "kill \$RUN_IMAGE_PID; exit" TERM
  wait \$RUN_IMAGE_PID
  exit_code=\$?
  trap - TERM

  if [ \$exit_code -eq $EXIT-CODE-UPGRADE ]; then
    # Move scratch into the place of the inactive ota and switch current.
    echo
    echo
    echo "****************************************"
    echo "*** Switching firmware to \$next"
    echo "****************************************"
    # Remove any old backup.
    rm -rf \$PREFIX/\$next.old
    # Move the old ota to the backup.
    if [ -e \$PREFIX/\$next ]; then
      mv \$PREFIX/\$next \$PREFIX/\$next.old
    fi
    # Move the scratch in place.
    mv \$PREFIX/scratch \$PREFIX/\$next
    # Update the current pointer.
    echo \$next > \$PREFIX/current
    # Switch the current and next variables.
    tmp=\$next
    next=\$current
    current=\$tmp
  elif [ \$exit_code -eq $EXIT-CODE-STOP ]; then
    # Stop the script.
    echo "****************************************"
    echo "*** Stopping the boot script"
    echo "****************************************"
    break
  else
    if [ ! \$exit_code -eq 0 -a ! \$exit_code -eq $EXIT-CODE-ROLLBACK-REQUESTED ]; then
      echo "***********************************************"
      echo "*** Firmware crashed with code=\$exit_code"
      echo "***********************************************"
      # Clear the flash-registry in case it was corrupted.
      rm -f \$PREFIX/flash-registry
    fi
    if [ ! -e \$PREFIX/\$current/validated ]; then
      if [ \$exit_code -eq $EXIT-CODE-ROLLBACK-REQUESTED ]; then
        echo "****************************************"
        echo "*** Rollback requested"
        echo "****************************************"
      else
        echo "****************************************"
        echo "*** Validation failed. Rolling back."
        echo "****************************************"
      fi
      # Update the current pointer.
      echo \$next > \$PREFIX/current
      # Switch the current and next variables.
      tmp=\$next
      next=\$current
      current=\$tmp
      # Sleep a bit.
      sleep 1
    fi
  fi
done
"""
