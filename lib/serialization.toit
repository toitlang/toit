// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.tison
import bytes

/**
Serialization support.

The serialization format may change and should not be relied on.
*/

/**
Serializes the $object into a byte array.

The $object must be serializable.

This is the inverse operation of $deserialize.

# Parameter
The $object must be one of the following:
- string
- int
- float
- boolean
- null
- {:} ($Map)
- #[] ($ByteArray)
- [] ($List)
- $bytes.Producer
For $Map and $List, the contents must be serializable.

Deprecated. Use encoding.tison.encode instead.
*/
serialize object/any -> ByteArray:
  return tison.encode object

/**
Deserializes the $bytes into an object.

The $bytes must be produced by $serialize or use the same encoding.

The inverse of $serialize.

Deprecated. Use encoding.tison.decode instead.
*/
deserialize bytes/ByteArray -> any:
  return tison.decode bytes
