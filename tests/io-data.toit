// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io

class FakeData implements io.Data:
  data_ / io.Data

  constructor .data_:

  byte-size -> int:
    return data_.byte-size

  byte-at index/int -> int:
    return data_.byte-at index

  byte-slice from/int to/int -> FakeData:
    return FakeData (data_.byte-slice from to)

  write-to-byte-array byte-array/ByteArray --at/int from/int to/int -> none:
    data_.write-to-byte-array byte-array from to --at=at
