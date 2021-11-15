// Copyright (C) 2018 Toitware ApS.
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

namespace toit {

class Visitor {
 public:
  Visitor() {}
  virtual ~Visitor() {}
  void accept(Object* object);

 protected:
  virtual void visit_smi(Smi* smi) = 0;
  virtual void visit_string(String* string) = 0;
  virtual void visit_array(Array* array) = 0;
  virtual void visit_byte_array(ByteArray* byte_array) = 0;
  virtual void visit_stack(Stack* stack) = 0;
  virtual void visit_instance(Instance* instance) = 0;
  virtual void visit_oddball(HeapObject* oddball) = 0;
  virtual void visit_double(Double* value) = 0;
  virtual void visit_large_integer(LargeInteger* large_integer) = 0;
  virtual void visit_task(Task* value) = 0;
};

} // namespace toit
