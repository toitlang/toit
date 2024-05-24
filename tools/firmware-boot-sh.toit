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
#   <prefix>/secret.ubjson
#   <prefix>/current -> <prefix>/ota0 (symbolic link)
#
#   <prefix>/ota0/metadata/this.txt <- (contains "ota0")
#   <prefix>/ota0/metadata/next.txt <- (contains "ota1")
#   <prefix>/ota0/config.ubjson
#   <prefix>/ota0/flash.registry
#   <prefix>/ota0/flash.uuid
#   <prefix>/ota0/flash.validity
#   <prefix>/ota0/toit.boot
#   <prefix>/ota0/toit.boot.image
#
#   <prefix>/ota1/metadata/this.txt <- (contains "ota1")
#   <prefix>/ota1/metadata/next.txt <- (contains "ota0")
#   <prefix>/ota1/config.ubjson
#   <prefix>/ota0/flash.registry
#   <prefix>/ota0/flash.uuid
#   <prefix>/ota0/flash.validity
#   <prefix>/ota0/toit.boot
#   <prefix>/ota0/toit.boot.image

# Compute the directory of this script and use it as the PREFIX.
PREFIX=\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Check if we can find the secret.ubjson file.
export TOIT_SECURE_DATA=\$(realpath \$PREFIX/secret.ubjson)
if [ ! -f "\$TOIT_SECURE_DATA" ]; then
  echo "Cannot locate identity file: \$TOIT_SECURE_DATA"
  exit 1
fi

# Create the 'current' symlink to 'ota0' if it doesn't exist yet.
if [ ! -d "\$PREFIX/current" ]; then
  ln -sTf \$PREFIX/ota0 \$PREFIX/current
fi

for (( ; ; )); do
  this=\$(cat \$PREFIX/current/metadata/this.txt)
  next=\$(cat \$PREFIX/current/metadata/next.txt)
  echo "*******************************"
  echo "*** Running from \$this"
  echo "*******************************"

  export TOIT_CONFIG_DATA=\$(realpath \$PREFIX/current/config.ubjson)
  export TOIT_FLASH_REGISTRY_FILE=\$(realpath \$PREFIX/current/flash.registry)
  export TOIT_FLASH_UUID_FILE=\$(realpath \$PREFIX/current/flash.uuid)

  (cd \$PREFIX/current; ./toit.boot toit.boot.image)
  exit_code=\$?

  if [ \$exit_code -eq 17 ]; then
    echo
    echo
    echo "****************************************"
    echo "*** Testing firmware update in \$next"
    echo "****************************************"
    export TOIT_CONFIG_DATA=\$(realpath \$PREFIX/\$next/config.ubjson)
    export TOIT_FLASH_REGISTRY_FILE=\$(realpath \$PREFIX/\$next/flash.registry)
    export TOIT_FLASH_UUID_FILE=\$(realpath \$PREFIX/\$next/flash.uuid)
    rm -f \$TOIT_FLASH_UUID_FILE
    (cd \$PREFIX/\$next && tar --overwrite -xzf ../current/firmware.tgz && ./toit.boot toit.boot.image)
    firmware_update_exit_code=\$?
    echo
    echo
    if [ \$firmware_update_exit_code -eq 0 ]; then
      ln -sTf \$PREFIX/\$next \$PREFIX/current
      echo "****************************************"
      echo "*** Firmware update done: \$this -> \$next"
      echo "****************************************"
    else
      echo "****************************************"
      echo "*** Firmware update failed (still \$this)"
      echo "****************************************"
    fi
    echo
    echo
  elif [ \$exit_code -eq 0 ]; then
    echo "****************************************"
    echo "*** Firmware restarting (still \$this)"
    echo "****************************************"
  else
    echo "***********************************************"
    echo "*** Firmware crashed with code=\$exit_code (still \$this)"
    echo "***********************************************"
    # Clear flash.registry and flash.validity files and try again.
    rm -f \$TOIT_FLASH_REGISTRY_FILE \$PREFIX/current/flash.validity
    sleep 5
  fi
done
"""
