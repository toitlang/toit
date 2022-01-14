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

namespace toit {
namespace compiler {

// From https://microsoft.github.io/language-server-protocol/specification#textDocument_completion
enum class CompletionKind {
  NONE = -1,  // Not standard. Just used internally to indicate that no kind was given.
  TEXT = 1,
  METHOD = 2,
  FUNCTION = 3,
  CONSTRUCTOR = 4,
  FIELD = 5,
  VARIABLE = 6,
  CLASS = 7,
  INTERFACE = 8,
  MODULE = 9,
  PROPERTY = 10,
  UNIT = 11,
  VALUE = 12,
  ENUM = 13,
  KEYWORD = 14,
  SNIPPET = 15,
  COLOR = 16,
  FILE = 17,
  REFERENCE = 18,
  FOLDER = 19,
  ENUM_MEMBER = 20,
  CONSTANT = 21,
  STRUCT = 22,
  EVENT = 23,
  OPERATOR = 24,
  TYPE_PARAMETER = 25,
};

} // namespace toit::compiler
} // namespace toit
