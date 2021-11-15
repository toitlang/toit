// Copyright (C) 2021 Toitware ApS.
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

#include <list>

#include "source_mapper.h"
#include "ir.h"
#include "resolver_primitive.h"
#include "set.h"

namespace toit {
namespace compiler {

class SourceInfoCollector;

// String table for canonicalize strings.
class StringTable {
 public:
  int find_index_for(const char* string) {
    if (_map.find(string) != _map.end()) return _map[string];
    int index = table.size();
    _map[string] = index;
    table.push_back(string);
    return index;
  }
  void visit(SourceInfoCollector* collector);

 private:
  std::list<std::string> table;
  std::map<std::string, int> _map;
};

// Abstract class for collecting source info.
class SourceInfoCollector {
 public:
  virtual void write_byte(uint8 value) = 0;
  virtual void write_string(const char* value) = 0;
  virtual void write_string_content(const char* value) = 0;

  void write_int(int value) {
    ASSERT(value >= 0);
    while (value >= 128) {
      write_byte((uint8) (value % 128 + 128));
      value >>= 7;
    }
    write_byte((uint8) value);
  }

  const int INT_SIZE = 4;
};

void StringTable::visit(SourceInfoCollector* collector) {
  collector->write_int(table.size());
  for (auto string : table) collector->write_string_content(string.c_str());
}

class SourceInfoAllocator: public SourceInfoCollector {
 public:
  SourceInfoAllocator(StringTable* strings = null) : _strings(strings) {}

  void write_string(const char* value) {
    write_int(_strings->find_index_for(value));
  }

  void write_string_content(const char* value) {
    int len = value == null ? 0 : strlen(value);
    write_int(len);
    _size += len;
  }

  void write_byte(uint8 value) { _size++; }

  int size() { return _size; }

 private:
  int _size = INT_SIZE * 2;
  StringTable* _strings;
};

class SourceInfoEmitter: public SourceInfoCollector {
 public:
  SourceInfoEmitter(uint8* buffer, StringTable* strings) : buffer(buffer), _strings(strings) {}

  void write_header(int tag, int size) {
    write_header_int(tag);
    write_header_int(size);
  }

  void write_byte(uint8 value) {
     buffer[pos++] = value;
  }

  void write_string(const char* value) {
    write_int(_strings->find_index_for(value));
  }

  void write_string_content(const char* value) {
    int len = strlen(value);
    write_int(len);
    memcpy(&buffer[pos], value, len);
    pos += len;
  }

 private:
  int pos = 0;
  uint8* buffer;
  StringTable* _strings;

  void write_header_int(int value) {
    ASSERT(value >= 0);
    for (int i = 0; i < 4; i++) {
      buffer[pos + i] = value & 0xFF;
      value >>= 8;
    }
    pos += INT_SIZE;
  }
};

void SourceMapper::visit_selectors(SourceInfoCollector* collector) {
  // For now just write unique
  collector->write_int(_selectors.size());
  for (auto location_id : _selectors.keys()) {
    collector->write_int(location_id);
    auto selector_class_entry = _selectors.at(location_id);
    int encoded_super_id = selector_class_entry.super_location_id + 1;
    collector->write_int(encoded_super_id);
    collector->write_int(selector_class_entry.selectors.size());
    for (auto selector : selector_class_entry.selectors) {
      collector->write_string(selector.c_str());
    }
  }
}

void SourceMapper::visit_method_info(SourceInfoCollector* collector) {
  collector->write_int(_source_information.size());
  for (auto entry : _source_information) {
    collector->write_int(entry.id);
    collector->write_int(entry.bytecode_size);
    collector->write_byte(static_cast<uint8>(entry.type));
    int outer = entry.outer;
    if (is_encoded_outer_index(outer)) {
      outer = decode_outer_index(outer);
      ASSERT(outer >= 0);
    }
    if (outer == -1) {
      // No outer-id.
      collector->write_byte(0);
    } else {
      collector->write_byte(1);
      collector->write_int(outer);
    }
    collector->write_string(entry.name);
    collector->write_string(entry.holder_name);
    collector->write_string(entry.absolute_path);
    collector->write_string(entry.error_path.c_str());
    collector->write_int(entry.position.line);
    collector->write_int(entry.position.column);
    collector->write_int(entry.bytecode_positions.size());
    for (auto pair : entry.bytecode_positions) {
      collector->write_int(pair.first);
      collector->write_int(pair.second.line);
      collector->write_int(pair.second.column);
    }
    collector->write_int(entry.as_class_names.size());
    for (auto pair : entry.as_class_names) {
      collector->write_int(pair.first);
      collector->write_string(pair.second);
    }
    collector->write_int(entry.pubsub_info.size());
    for (auto entry : entry.pubsub_info) {
      collector->write_int(entry.bytecode_offset);
      collector->write_int(entry.target_dispatch_index);
      if (entry.topic == null) {
        collector->write_byte(0);
        collector->write_string("");
      } else {
        collector->write_byte(1);
        collector->write_string(entry.topic);
      }
    }
  }
}

void SourceMapper::visit_class_info(SourceInfoCollector* collector) {
  collector->write_int(_class_information.size());
  int id = 0;
  for (auto klass : _class_information.keys()) {
    // We don't need to encode the id, as it's given by the index in the class-table.
    ASSERT(klass->id() == id++);
    auto entry = _class_information[klass];
    int encoded_super = entry.super + 1;
    collector->write_int(encoded_super);
    collector->write_int(entry.location_id);
    collector->write_string(entry.name);
    collector->write_string(entry.absolute_path);
    collector->write_string(entry.error_path.c_str());
    collector->write_int(entry.position.line);
    collector->write_int(entry.position.column);
    collector->write_int(entry.fields.size());
    for (auto name : entry.fields) {
      collector->write_string(name);
    }
  }
}

void SourceMapper::visit_primitive_info(SourceInfoCollector* collector) {
  const int number_of_primitive_modules = PrimitiveResolver::number_of_modules();
  collector->write_int(number_of_primitive_modules);
  for (int module = 0; module < number_of_primitive_modules; module++) {
    collector->write_string(PrimitiveResolver::module_name(module));
    const int number_of_primitives = PrimitiveResolver::number_of_primitives(module);
    collector->write_int(number_of_primitives);
    for (int index = 0; index < number_of_primitives; index++) {
      collector->write_string(PrimitiveResolver::primitive_name(module, index));
    }
  }
}

void SourceMapper::visit_selector_offset_info(SourceInfoCollector* collector) {
  collector->write_int(_selector_offsets.size());
  for (auto p : _selector_offsets) {
    collector->write_int(p.first);
    collector->write_string(p.second);
  }
}

void SourceMapper::visit_global_info(SourceInfoCollector* collector) {
  collector->write_int(_global_information.size());
  for (auto info : _global_information) {
    collector->write_string(info.name);
    collector->write_string(info.holder_name);
    int encoded_holder_class_id = info.holder_class_id + 1;
    ASSERT(encoded_holder_class_id >= 0);
    collector->write_int(encoded_holder_class_id);
  }
}

uint8* SourceMapper::cook(int* size) {
  StringTable string_table;
  // Compute how much memory is needed for the source info segments.
  SourceInfoAllocator method_segment(&string_table);
  visit_method_info(&method_segment);
  SourceInfoAllocator class_segment(&string_table);
  visit_class_info(&class_segment);
  SourceInfoAllocator primitive_segment(&string_table);
  visit_primitive_info(&primitive_segment);
  SourceInfoAllocator global_segment(&string_table);
  visit_global_info(&global_segment);
  SourceInfoAllocator selector_offset_segment(&string_table);
  visit_selector_offset_info(&selector_offset_segment);
  SourceInfoAllocator selectors_segment(&string_table);
  visit_selectors(&selectors_segment);
  // The string-table must be visited last, as it collects the strings from all other segments.
  SourceInfoAllocator string_segment;
  string_table.visit(&string_segment);

  // Allocated the buffer needed for all the source info.
  *size = method_segment.size()
      + class_segment.size()
      + primitive_segment.size()
      + string_segment.size()
      + selector_offset_segment.size()
      + global_segment.size()
      + selectors_segment.size();
  uint8* buffer = unvoid_cast<uint8*>(malloc(*size));
  if (buffer == null) FATAL("Couldn't allocate memory for source info");

  // Emit all the source info segments.
  SourceInfoEmitter writer(buffer, &string_table);
  writer.write_header(70177018, string_segment.size());
  string_table.visit(&writer);
  writer.write_header(70177019, method_segment.size());
  visit_method_info(&writer);
  writer.write_header(70177020, class_segment.size());
  visit_class_info(&writer);
  writer.write_header(70177021, primitive_segment.size());
  visit_primitive_info(&writer);
  writer.write_header(70177023, global_segment.size());
  visit_global_info(&writer);
  writer.write_header(70177022, selector_offset_segment.size());
  visit_selector_offset_info(&writer);
  writer.write_header(70177024, selectors_segment.size());
  visit_selectors(&writer);

  return buffer;
}


SourceMapper::MethodEntry SourceMapper::build_method_entry(int index,
                                                           MethodType type,
                                                           int outer,
                                                           const char* name,
                                                           const char* holder_name,
                                                           Source::Range range) {
  auto location = _manager->compute_location(range.from());
  return {
    .index = index,
    .id = -1,  // Set to -1, and must be updated later.
    .bytecode_size = -1,
    .type = type,
    .name = name,
    .holder_name = holder_name,
    .absolute_path = location.source->absolute_path(),
    .error_path = location.source->error_path(),
    .position = {
      .line = location.line_number,
      .column = location.offset_in_line + 1,  // Offsets are 0-based, but columns are 1-based.
    },
    .outer = outer,
  };
}

void SourceMapper::register_selectors(List<ir::Class*> classes) {
  for (auto klass : classes) {
    int location_id = klass->location_id();
    if (location_id == -1) continue;
    int super_id = klass->has_super() ? klass->super()->location_id() : -1;

    Set<std::string> selector_names;
    for (auto method : klass->methods()) {
      std::string name(method->name().c_str());
      if (method->is_setter()) {
        name += "=";
      }
      selector_names.insert(name);
    }
    for (auto field : klass->fields()) {
      std::string name(field->name().c_str());
      selector_names.insert(name);
      selector_names.insert(name + "=");
    }
    _selectors[location_id] = {
      .super_location_id = super_id,
      .selectors = selector_names.to_vector(),
    };
  }
}

void SourceMapper::add_class_entry(int id,
                                   ir::Class* klass) {
  ASSERT(klass->name().is_valid());
  auto name = klass->name().c_str();
  auto position = klass->range().from();
  auto location_id = klass->location_id();
  std::vector<const char*> fields;
  fields.reserve(klass->fields().length());
  for (auto field : klass->fields()) {
    fields.push_back(field->name().c_str());
  }
  auto location = _manager->compute_location(position);
  _class_information[klass] = {
    .id = id,
    .super = klass->has_super() ? klass->super()->id() : -1,
    .location_id = location_id,
    .name = name,
    .absolute_path = location.source->absolute_path(),
    .error_path = location.source->error_path(),
    .position = {
      .line = location.line_number,
      .column = location.offset_in_line + 1,  // Offsets are 0-based, but columns are 1-based.
    },
    .fields = fields,
  };
}

void SourceMapper::add_global_entry(ir::Global* global) {
  ASSERT(static_cast<int>(_global_information.size()) == global->global_id());
  // For globals with initializers, we duplicate the holder-id and holder-name information.
  int holder_id;
  const char* holder_name;
  extract_holder_information(global->holder(), &holder_id, &holder_name);
  _global_information.push_back({
    .name = global->name().c_str(),
    .holder_name = holder_name,
    .holder_class_id = holder_id,
  });
}

SourceMapper::MethodMapper SourceMapper::register_method(ir::Method* method) {
  int index = _source_information.size();
  auto name = method->name().c_str();
  if (method->is_setter()) {
    int len = strlen(name);
    auto name_with_assign = unvoid_cast<char*>(malloc(len + 2));
    memcpy(name_with_assign, name, len);
    name_with_assign[len] = '=';
    name_with_assign[len + 1] = '\0';
    name = name_with_assign;
  }
  auto range = method->range();
  MethodType type;
  switch (method->kind()) {
    case ir::Method::INSTANCE:
      type = MethodType::TOPLEVEL;
      break;

    case ir::Method::GLOBAL_FUN:
    case ir::Method::GLOBAL_INITIALIZER:
    case ir::Method::CONSTRUCTOR:
    case ir::Method::FACTORY:
      // All static methods use the toplevel type.
      type = MethodType::TOPLEVEL;
      break;

    case ir::Method::FIELD_INITIALIZER:
      UNREACHABLE();
  }
  int holder_id;
  const char* holder_name;
  extract_holder_information(method->holder(), &holder_id, &holder_name);
  _source_information.push_back(build_method_entry(index, type, holder_id, name, holder_name, range));
  return MethodMapper(this, index);
}

SourceMapper::MethodMapper SourceMapper::register_global(ir::Global* global) {
  int index = _source_information.size();
  auto name = global->name().c_str();
  auto range = global->range();
  // The source-information here is only for the initializer.
  // Globals that are initialized with a constant are not called here.
  int holder_id;
  const char* holder_name;
  extract_holder_information(global->holder(), &holder_id, &holder_name);
  _source_information.push_back(build_method_entry(index, MethodType::GLOBAL, holder_id, name, holder_name, range));
  return MethodMapper(this, index);
}

SourceMapper::MethodMapper SourceMapper::register_lambda(int outer_index, ir::Code* code) {
  int index = _source_information.size();
  auto name = "<lambda>";
  auto range = code->range();
  int encoded_outer = encode_outer_index(outer_index);
  _source_information.push_back(build_method_entry(index, MethodType::LAMBDA, encoded_outer, name, "", range));
  return MethodMapper(this, index);
}

SourceMapper::MethodMapper SourceMapper::register_block(int outer_index, ir::Code* code) {
  int index = _source_information.size();
  auto name = "<block>";
  auto range = code->range();
  int encoded_outer = encode_outer_index(outer_index);
  _source_information.push_back(build_method_entry(index, MethodType::BLOCK, encoded_outer, name, "", range));
  return MethodMapper(this, index);
}

void SourceMapper::register_bytecode(int method_index, int bytecode_offset, Source::Range range) {
  ASSERT(method_index >= 0);
  auto& method_data = _source_information[method_index];
  auto location = _manager->compute_location(range.from());
  method_data.bytecode_positions[bytecode_offset] = {
    .line = location.line_number,
    .column = location.offset_in_line + 1,  // Offsets are 0-based, but columns are 1-based.
  };
}

void SourceMapper::register_as(int method_index, int bytecode_offset, const char* class_name) {
  ASSERT(method_index >= 0);
  auto& method_data = _source_information[method_index];
  method_data.as_class_names[bytecode_offset] = class_name;
}

void SourceMapper::register_pubsub_call(int method_index,
                                        int bytecode_offset,
                                        int target_dispatch_index,
                                        const char* topic) {
  ASSERT(method_index >= 0);
  auto& method_data = _source_information[method_index];
  method_data.pubsub_info.push_back({
    .bytecode_offset = bytecode_offset,
    .target_dispatch_index = target_dispatch_index,
    .topic = topic,
  });
}

void SourceMapper::extract_holder_information(ir::Class* holder,
                                              int* holder_id,
                                              const char** holder_name) {
  *holder_id = -1;
  *holder_name = "";
  if (holder != null) {
    // We can't ask the holder for its id directly, as the class might not be instantiated.
    *holder_id = id_for_class(holder);
    // We get the name directly from the holder, as we might not even have an
    // id from the `id_for_class` function, as we don't have any class information
    // for classes that have been entirely tree-shaken.
    auto holder_symbol = holder->name();
    if (holder_symbol.is_valid()) *holder_name = holder_symbol.c_str();
  }
}

} // namespace toit::compiler
} // namespace toit
