# Copyright (C) 2018 Toitware ApS.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

import sys
import hashlib

def md5(fname):
    hash_md5 = hashlib.md5()
    with open(fname, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()

f = open(sys.argv[1], 'w+')
hash = md5(sys.argv[2])
f.write('namespace toit {\n\n');
f.write('unsigned int checksum[4] = {')
for i in range(0, 4):
    if i != 0: f.write(', ')
    f.write('0x' + hash[i * 8:(i + 1) * 8])
f.write('};\n\n')
f.write('}\n')
f.close()
