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

#pragma once

#include <string>
#include <map>
#include <vector>

#include "../top.h"
#include "sources.h"

namespace toit {
namespace compiler {

namespace ir {
class Global;
class Method;
class Code;
class Class;
}  // namespace toit::compiler::ir

class SourceInfoCollector;

enum class MethodType {
  INSTANCE      = 0,
  GLOBAL        = 1,
  LAMBDA        = 2,
  BLOCK         = 3,
  TOPLEVEL      = 4
};

class SourceMapper {
 public:
  class MethodMapper {
   public:
    static MethodMapper invalid() { return MethodMapper(null, -1); }

    bool is_valid() const { return _source_mapper != null; }

    void register_call(int bytecode_offset, Source::Range range) {
      ASSERT(is_valid());
      ASSERT(!_is_finalized);
      _source_mapper->register_bytecode(_method_index, bytecode_offset, range);
    }

    void register_as_check(int bytecode_offset, Source::Range range, const char* class_name) {
      ASSERT(is_valid());
      ASSERT(!_is_finalized);
      _source_mapper->register_bytecode(_method_index, bytecode_offset, range);
      _source_mapper->register_as(_method_index, bytecode_offset, class_name);
    }

    void register_pubsub_call(int bytecode_offset, int target_dispatch_index, const char* topic) {
      ASSERT(is_valid());
      ASSERT(!_is_finalized);
      _source_mapper->register_pubsub_call(_method_index, bytecode_offset, target_dispatch_index, topic);
    }

    void finalize(int method_id, int size) {
      ASSERT(is_valid());
      ASSERT(!_is_finalized);
      _is_finalized = true;
      ASSERT(method_id >= 0);
      ASSERT(size >= 0);
      ASSERT(_source_mapper->_source_information[_method_index].id == -1);
      _source_mapper->_source_information[_method_index].id = method_id;
      ASSERT(_source_mapper->_source_information[_method_index].bytecode_size == -1);
      _source_mapper->_source_information[_method_index].bytecode_size = size;
    }

    MethodMapper register_lambda(ir::Code* code) {
      ASSERT(is_valid());
      return _source_mapper->register_lambda(_method_index, code);
    }
    MethodMapper register_block(ir::Code* code) {
      ASSERT(is_valid());
      return _source_mapper->register_block(_method_index, code);
    }

   private:
    friend class SourceMapper;
    MethodMapper(SourceMapper* source_mapper, int method_index)
        : _source_mapper(source_mapper), _method_index(method_index) { }

    SourceMapper* _source_mapper;
    int _method_index;
    bool _is_finalized = false;
  };

  explicit SourceMapper(SourceManager* manager) : _manager(manager) { }

  /// Returns a malloced buffer of the source-map.
  uint8* cook(int* size);
  MethodMapper register_method(ir::Method* method);
  MethodMapper register_global(ir::Global* global);

  // Records the selectors of all classes.
  // This should be done with resolution shapes and before
  // introducing stub-methods. (At least as much as possible).
  void register_selectors(List<ir::Class*> classes);

  void add_class_entry(int id, ir::Class* klass);
  void add_global_entry(ir::Global* global);

  int id_for_class(ir::Class* klass) {
    auto probe = _class_information.find(klass);
    if (probe == _class_information.end()) return -1;
    return probe->second.id;
  }

  void register_selector_offset(int offset, const char* name) {
    _selector_offsets[offset] = name;
  }

 private:
  struct FilePosition {
    int line;
    int column;
  };

  struct PubsubEntry {
    int bytecode_offset;
    int target_dispatch_index;
    const char* topic;
  };

  struct MethodEntry {
    int index;  // The index in the source-mapping table.
    int id;     // The actual id of the method.
    int bytecode_size;
    MethodType type;
    const char* name;
    // The empty string, or the name of the class surrounding this method.
    // We can't always use the `outer` for this, as classes may be tree-shaken
    //   if this method is a static method.
    const char* holder_name;
    const char* absolute_path;
    std::string error_path;
    FilePosition position;
    // The `outer` field encodes the id and type of the outer.
    // In methods, `outer` is the id of the holder class.
    // For blocks/lambdas:
    //   If the `outer` is negative, then it is the *index* of the
    //     method-entry that surrounds the method.
    int outer;
    // We use an *ordered* map here, which will sort the entries by
    // bytecodes.
    std::map<int, FilePosition> bytecode_positions;
    std::map<int, const char*> as_class_names;
    std::vector<PubsubEntry> pubsub_info;
  };

  struct ClassEntry {
    int id;
    int super;
    // An id representing the location of the class.
    // For the current compilation, the location_id is equivalent to the path+position.
    int location_id;
    const char* name;
    const char* absolute_path;
    std::string error_path;
    FilePosition position;
    std::vector<const char*> fields;
  };

  struct GlobalEntry {
    const char* name;
    // The empty string, or the name of the class surrounding this method.
    // We can't always use the `outer` for this, as classes may be tree-shaken
    //   if this method is a static method.
    const char* holder_name;
    // The class-id of the holder class.
    // If the global is on the top-level equal to -1.
    int holder_class_id;
  };

  struct SelectorClassEntry {
    int super_location_id;  // -1 if absent.
    std::vector<std::string> selectors;
  };

  friend class MethodMapper;
  SourceManager* _manager;

  MethodMapper register_lambda(int outer_id, ir::Code* code);
  MethodMapper register_block(int outer_id, ir::Code* code);

  // Helper methods to iterate over source info for generating debug info.
  void visit_selectors(SourceInfoCollector* collector);
  void visit_method_info(SourceInfoCollector* collector);
  void visit_class_info(SourceInfoCollector* collector);
  void visit_primitive_info(SourceInfoCollector* collector);
  void visit_selector_offset_info(SourceInfoCollector* collector);
  void visit_global_info(SourceInfoCollector* collector);

  MethodEntry build_method_entry(int id,
                                 MethodType type,
                                 int outer,
                                 const char* name,
                                 const char* holder_name,
                                 Source::Range range);
  void register_bytecode(int method_id, int bytecode_offset, Source::Range range);
  void register_as(int method_id, int bytecode_offset, const char* class_name);
  void register_pubsub_call(int method_id, int bytecode_offset, int target_dispatch_index, const char* topic);

  std::vector<MethodEntry> _source_information;
  Map<ir::Class*, ClassEntry> _class_information;
  std::map<int, const char*> _selector_offsets;
  std::vector<GlobalEntry> _global_information;
  // Map from location-id to selector class-entry.
  Map<int, SelectorClassEntry> _selectors;

  void extract_holder_information(ir::Class* holder,
                                  int* holder_id,
                                  const char** holder_name);

  // Encodes the given [index], so it can be distinguished from normal ids.
  // We also have to make sure to distinguish the encoded value from -1 (which signals no index).
  static int encode_outer_index(int index) { return -index - 2; }
  // Whether [outer] is an encoded index instead of an id.
  bool is_encoded_outer_index(int outer) { return outer < -1; }
  int decode_outer_index(int outer) {
    ASSERT(is_encoded_outer_index(outer));
    return _source_information[-outer - 2].id;
  }
};

} // namespace toit::compiler
} // namespace toit
