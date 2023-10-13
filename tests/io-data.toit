// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import io

class FakeData implements io.Data:
  data_ / ByteArray

  constructor .data_:

  constructor.str str/string:
    data_ = str.to-byte-array

  size -> int: return data_.size

  write-to-byte-array byte-array/ByteArray --at/int from/int to/int -> none:
    data_.write-to-byte-array byte-array from to --at=at

  operator[..] --from/int=0 --to/int=size -> io.Data:
    return FakeData data_[from..to]
