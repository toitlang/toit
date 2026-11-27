// Copyright (C) 2026 Toit contributors.
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

import uuid show Uuid

/**
Container operations needed by native firmware image builders.
*/
interface Container:
  relocatable -> ByteArray
  relocated-size -> int
  relocate --relocation-base/int --attach-assets/bool --system-uuid/Uuid -> ByteArray
