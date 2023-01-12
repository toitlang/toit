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
class Call;
class Class;
class Code;
class Expression;
class Global;
class Method;
class Node;
class ReferenceGlobal;
class Typecheck;
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

    bool is_valid() const { return source_mapper_ != null; }

    void register_call(ir::Call* call, int bytecode_offset);
    void register_call(ir::ReferenceGlobal* call, int bytecode_offset);
    void register_as_check(ir::Typecheck* check, int bytecode_offset);

    MethodMapper register_lambda(ir::Code* code) {
      return source_mapper()->register_lambda(method_index_, code);
    }

    MethodMapper register_block(ir::Code* code) {
      return source_mapper()->register_block(method_index_, code);
    }

    void finalize(int method_id, int size) {
      SourceMapper* mapper = source_mapper();
      is_finalized_ = true;
      ASSERT(method_id >= 0);
      ASSERT(size >= 0);
      ASSERT(mapper->source_information_[method_index_].id == -1);
      mapper->source_information_[method_index_].id = method_id;
      ASSERT(mapper->source_information_[method_index_].bytecode_size == -1);
      mapper->source_information_[method_index_].bytecode_size = size;
    }

   private:
    friend class SourceMapper;
    MethodMapper(SourceMapper* source_mapper, int method_index)
        : source_mapper_(source_mapper), method_index_(method_index) {}

    SourceMapper* source_mapper_;
    int method_index_;
    bool is_finalized_ = false;

    SourceMapper* source_mapper() const {
      ASSERT(is_valid());
      ASSERT(!is_finalized_);
      return source_mapper_;
    }
  };

  explicit SourceMapper(SourceManager* manager) : manager_(manager) {}

  SourceManager* manager() const { return manager_; }

  /// Returns a malloced buffer of the source-map.
  uint8* cook(int* size);
  MethodMapper register_method(ir::Method* method);
  MethodMapper register_global(ir::Global* global);

  // Records the selectors of all classes.
  // This should be done with resolution shapes and before
  // introducing stub-methods. (At least as much as possible).
  void register_selectors(List<ir::Class*> classes);

  void register_selector_offset(int offset, const char* name) {
    selector_offsets_[offset] = name;
  }

  void add_class_entry(int id, ir::Class* klass);
  void add_global_entry(ir::Global* global);

  int id_for_class(ir::Class* klass) const {
    auto probe = class_information_.find(klass);
    if (probe == class_information_.end()) return -1;
    return probe->second.id;
  }

  int position_for_method(ir::Node* node) const;
  int position_for_expression(ir::Expression* expression) const;

  std::vector<int> methods() const;

 private:
  struct FilePosition {
    int line;
    int column;
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
  SourceManager* manager_;

  MethodMapper register_lambda(int outer_id, ir::Code* code);
  MethodMapper register_block(int outer_id, ir::Code* code);

  // Helper methods to iterate over source info for generating debug info.
  void visit_selectors(SourceInfoCollector* collector);
  void visit_method_info(SourceInfoCollector* collector);
  void visit_class_info(SourceInfoCollector* collector);
  void visit_primitive_info(SourceInfoCollector* collector);
  void visit_selector_offset_info(SourceInfoCollector* collector);
  void visit_global_info(SourceInfoCollector* collector);

  MethodEntry build_method_entry(ir::Node* node,
                                 int id,
                                 MethodType type,
                                 int outer,
                                 const char* name,
                                 const char* holder_name,
                                 Source::Range range);
  void register_expression(ir::Expression* expression, int method_id, int bytecode_offset);
  void register_as_check(ir::Typecheck* check, int method_id, int bytecode_offset);

  std::vector<MethodEntry> source_information_;
  Map<ir::Class*, ClassEntry> class_information_;
  std::map<int, const char*> selector_offsets_;
  std::vector<GlobalEntry> global_information_;
  // Map from location-id to selector class-entry.
  Map<int, SelectorClassEntry> selectors_;

  // Map from method or code to method index.
  Map<ir::Node*, int> method_indexes_;
  // Map from expressions to method index and bytecode offset.
  Map<ir::Expression*, std::pair<int, int>> expression_positions_;

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
    return source_information_[-outer - 2].id;
  }
};

} // namespace toit::compiler
} // namespace toit
