// Copyright (C) 2022 Toitware ApS.
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

#pragma once

#include "top.h"
#include "utils.h"

namespace toit {

class EmbeddedDataExtension;

class EmbeddedData {
 public:
  // Get the unique 16-bytes uuid of the current 'firmware' image.
  static const uint8* uuid();

  // Get the extension of the embedded data section. Returns null
  // if no extension is present.
  static const EmbeddedDataExtension* extension();
};

struct EmbeddedImage {
  const Program* program;
  const uword size;
};

class EmbeddedDataExtension {
 public:
  int images() const;
  EmbeddedImage image(int n) const;

  List<uint8> config() const;

  uword offset(const Program* program) const;
  const Program* program(uword offset) const;

  static const EmbeddedDataExtension* cast(const void* pointer);

 private:
  static const uint32 HEADER_MARKER   = 0x98dfc301;
  static const uint32 HEADER_CHECKSUM = 0xb3147ee9;

  static const int HEADER_INDEX_MARKER      = 0;
  static const int HEADER_INDEX_USED        = 1;
  static const int HEADER_INDEX_FREE        = 2;
  static const int HEADER_INDEX_IMAGE_COUNT = 3;
  static const int HEADER_INDEX_CHECKSUM    = 4;
  static const int HEADER_WORDS             = 5;
};

}  // namespace toit
