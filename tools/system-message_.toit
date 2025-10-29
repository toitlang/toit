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

import encoding.base64
import encoding.ubjson
import uuid

// TODO(florian): this file should be called `system-message`, and the
// executable one (currently using `system-message.toit`) should be renamed.
// However, we can't do that until the `toit` executable has deprecated the
// individual tool commands.

class SystemMessage:
  sdk-version/string
  sdk-model/string
  program-uuid/uuid.Uuid
  payload/any

  constructor --.sdk-version --.sdk-model --.program-uuid --.payload:

decode-system-message bytes/ByteArray [--if-error] -> SystemMessage:
  decoded-json := null
  error ::= catch: decoded-json = ubjson.decode bytes
  if error:
    if-error.call error
    unreachable  // if_error callback shouldn't continue decoding.
  if decoded-json is not List: throw "Expecting a list when decoding a structure"
  if decoded-json.size != 5: throw "Expecting five element list"
  if decoded-json.first != 'X': throw "Expecting Message"
  return SystemMessage
      --sdk-version=decoded-json[1]
      --sdk-model=decoded-json[2]
      --program-uuid=uuid.Uuid decoded-json[3]
      --payload=decoded-json[4]
