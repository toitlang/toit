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

#include <functional>
#include <algorithm>
#include "../third_party/tiny-sha1/TinySHA1.hpp"
#include "protocol_summary.h"

#include "protocol.h"

#include "../ir.h"
#include "../map.h"
#include "../resolver_scope.h"
#include "../scanner.h"  // For "is_identifier_start"
#include "../sources.h"
#include "../toitdoc.h"
#include "../toitdoc_node.h"


namespace toit {
namespace compiler {

namespace {  // Anonymous namespace.

/// The path to an element.
struct ToitdocPath {
  enum class Kind {
    CLASS = 1,
    GLOBAL = 2,
    GLOBAL_METHOD = 3,
    STATIC_METHOD = 4,
    CONSTRUCTOR = 5,
    FACTORY = 6,
    METHOD = 7,
    FIELD = 8,
    PARAMETER = 9,
  };

  Kind kind;
  Module* module;
  // Holder, if the element is inside a class.
  ir::Class* klass;
};

template<typename T> static int length_of(const std::vector<T>& v) { return static_cast<int>(v.size()); }
template<typename T> static int length_of(const Set<T>& v) { return v.size(); }
template<typename T> static int length_of(const List<T>& v) { return v.length(); }

static bool is_operator_name(const char* name) {
  return !IdentifierValidator::is_identifier_start(name[0]);
}

class ToitdocWriter : public toitdoc::Visitor {
 public:
  ToitdocWriter(Toitdoc<ir::Node*> toitdoc,
                const UnorderedMap<ir::Node*, ToitdocPath>& paths,
                LspWriter* lsp_writer)
      : toitdoc_(toitdoc)
      , paths_(paths)
      , lsp_writer_(lsp_writer) {}

  void write() {
    visit(toitdoc_.contents());
  }

  void visit_Contents(toitdoc::Contents* node) {
    print_list(node->sections(), &ToitdocWriter::visit_Section);
  }

  void visit_Section(toitdoc::Section* node) {
    print_symbol(node->title());
    this->printf("%d\n", node->level());
    print_list(node->statements(), &ToitdocWriter::visit_Statement);
  }

  void visit_CodeSection(toitdoc::CodeSection* node) {
    this->printf("CODE SECTION\n");
    print_symbol(node->code());
  }

  void visit_Itemized(toitdoc::Itemized* node) {
    this->printf("ITEMIZED\n");
    print_list(node->items(), &ToitdocWriter::visit_Item);
  }

  void visit_Item(toitdoc::Item* node) {
    this->printf("ITEM\n");  // Not really necessary, as implied by the parent.
    print_list(node->statements(), &ToitdocWriter::visit_Statement);
  }

  void visit_Paragraph(toitdoc::Paragraph* node) {
    this->printf("PARAGRAPH\n");
    print_list(node->expressions(), &ToitdocWriter::visit_Expression);
  }

  void visit_Text(toitdoc::Text* node) {
    this->printf("TEXT\n");
    print_symbol(node->text());
  }

  void visit_Code(toitdoc::Code* node) {
    this->printf("CODE\n");
    print_symbol(node->text());
  }

  void visit_Link(toitdoc::Link* node) {
    this->printf("LINK\n");
    print_symbol(node->text());
    print_symbol(node->url());
  }

  void visit_Ref(toitdoc::Ref* node) {
    this->printf("REF\n");
    print_symbol(node->text());
    auto resolved = toitdoc_.refs()[node->id()];
    if (resolved == null) {
      this->printf("-1\n");
    } else if (resolved->is_Parameter()) {
      // For now just print the kind_id.
      this->printf("%d\n", static_cast<int>(ToitdocPath::Kind::PARAMETER));
    } else {
      auto path = paths_.at(resolved);
      int kind_id = static_cast<int>(path.kind);
      auto holder_name = Symbol::invalid();
      auto name = Symbol::invalid();
      auto shape = ResolutionShape::invalid();
      switch (path.kind) {
        case ToitdocPath::Kind::CLASS:
          name = resolved->as_Class()->name();
          break;

        case ToitdocPath::Kind::GLOBAL:
          name = resolved->as_Global()->name();
          break;

        case ToitdocPath::Kind::GLOBAL_METHOD:
          name = resolved->as_Method()->name();
          shape = resolved->as_Method()->resolution_shape();
          break;

        case ToitdocPath::Kind::STATIC_METHOD:
        case ToitdocPath::Kind::CONSTRUCTOR:
        case ToitdocPath::Kind::FACTORY:
        case ToitdocPath::Kind::METHOD: {
          auto method = resolved->as_Method();
          holder_name = path.klass->name();
          name = method->name();
          shape = method->resolution_shape();
          if (method->has_implicit_this()) {
            // For simplicity remove the implicit this argument in toit-refs.
            shape = shape.without_implicit_this();
          }
          break;
        }

        case ToitdocPath::Kind::FIELD:
          holder_name = path.klass->name();
          name = resolved->as_Field()->name();
          break;

        case ToitdocPath::Kind::PARAMETER:
          UNREACHABLE();
          // Nothing to do.
          break;
      }
      this->printf("%d\n", kind_id);
      this->printf("%s\n", path.module->unit()->absolute_path());
      if (holder_name.is_valid()) print_symbol(holder_name);
      if (name.is_valid() && is_operator_name(name.c_str())) {
        print_symbol(name, "operator ");
      } else {
        print_symbol(name);
      }
      if (shape.is_valid()) {
        print_shape(shape);
      }
    }
  }

  // The following functions are used as callbacks from `print_list`.
  void visit_Statement(toitdoc::Statement* node) { visit(node); }
  void visit_Expression(toitdoc::Expression* node) { visit(node); }

 private:
  Toitdoc<ir::Node*> toitdoc_;
  UnorderedMap<ir::Node*, ToitdocPath> paths_;
  LspWriter* lsp_writer_;

  template<typename T, typename T2>
  void print_list(T elements, void (ToitdocWriter::*callback)(T2)) {
    this->printf("%d\n", length_of(elements));
    for (auto element : elements) { (this->*callback)(element); }
  }

  void print_symbol(Symbol symbol, const char* prefix = "") {
    if (!symbol.is_valid()) {
      this->printf("0\n\n");
    } else {
      const char* str = symbol.c_str();
      size_t length = strlen(prefix) + strlen(str);
      this->printf("%zd\n%s%s\n", length, prefix, str);
    }
  }

  void print_shape(const ResolutionShape& shape) {
    // We are not dealing with optional arguments, as we know that the
    //   functions are unique and don't overlap. (At least in theory).
    this->printf("%d\n", shape.max_arity());
    this->printf("%d\n", shape.total_block_count());
    this->printf("%d\n", shape.names().length());
    this->printf("%d\n", shape.named_block_count());
    this->printf("%s\n", shape.is_setter() ? "setter" : "not-setter");
    for (auto name : shape.names()) {
      print_symbol(name);
    }
  }

  void printf(const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    lsp_writer_->printf(format, arguments);
    va_end(arguments);
  }
};

class BufferedWriter : public LspWriter {
 public:
  BufferedWriter() : buffer_(unvoid_cast<uint8*>(malloc(1024))), capacity_(1024), length_(0) {}
  ~BufferedWriter() { free(buffer_); }

  void printf(const char* format, va_list& arguments) override {
    va_list args_copy;
    va_copy(args_copy, arguments);
    int size = vsnprintf(NULL, 0, format, args_copy);
    va_end(args_copy);

    if (size < 0) FATAL("Failure to convert argument to string");

    if (length_ + size >= capacity_) {
      grow(size);
    }

    vsnprintf(reinterpret_cast<char*>(buffer_ + length_), size + 1, format, arguments);
    length_ += size;
  }

  void write(const uint8* data, int size) override {
    if (length_ + size >= capacity_) {
      grow(size);
    }

    memcpy(buffer_ + length_, data, size);
    length_ += size;
  }

  int length() const { return length_; }
  uint8* data() { return buffer_; }

 private:
  uint8* buffer_;
  int capacity_;
  int length_;

  void grow(int size) {
    int new_capacity = capacity_ * 2;
    while (length_ + size >= new_capacity) {
      new_capacity *= 2;
    }

    uint8* new_buffer = unvoid_cast<uint8*>(malloc(new_capacity));
    memcpy(new_buffer, buffer_, length_);
    free(buffer_);
    buffer_ = new_buffer;
    capacity_ = new_capacity;
  }
};

class Writer {
 public:
  explicit Writer(const std::vector<Module*>& modules,
                  const ToitdocRegistry& toitdocs,
                  int core_index,
                  const UnorderedMap<ir::Node*, ToitdocPath>& paths,
                  LspWriter* lsp_writer)
      : modules_(modules)
      , toitdocs_(toitdocs)
      , core_index_(core_index)
      , paths_(paths)
      , lsp_writer_(lsp_writer) {}

  void print_modules();

 private:
  sha1::SHA1 sha1_;
  const std::vector<Module*> modules_;
  ToitdocRegistry toitdocs_;
  int core_index_;
  UnorderedMap<ir::Node*, ToitdocPath> paths_;
  UnorderedMap<ir::Node*, int> toplevel_ids_;
  List<int> module_offsets_;

  LspWriter* lsp_writer_;
  Source* current_source_ = null;

  template<typename T> void print_toitdoc(T node);
  void print_range(const Source::Range& range);
  void safe_print_symbol(Symbol symbol);
  void safe_print_symbol_external(Symbol symbol);
  void print_toplevel_ref(ir::Node* toplevel_element);
  void print_type(ir::Type type);
  void print_method(ir::Method* method);
  void print_class(ir::Class* klass);
  void print_field(ir::Field* field);
  void print_export(Symbol id, const ResolutionEntry& entry);
  void print_dependencies(Module* module);
  void print_module(Module* module, Module* core_module);


  template<typename T, typename T2>
  void print_list(T elements, void (Writer::*callback)(T2)) {
    this->printf("%d\n", length_of(elements));
    for (auto element : elements) { (this->*callback)(element); }
  }

  template<typename T, typename F>
  void print_list(T elements, F callback) {
    this->printf("%d\n", length_of(elements));
    for (auto element : elements) { callback(element); }
  }

  template<typename T, typename T2>
  void print_list_external(T elements, void (Writer::*callback)(T2)) {
    this->printf_external("%d\n", length_of(elements));
    for (auto element : elements) { (this->*callback)(element); }
  }

  template<typename T, typename F>
  void print_list_external(T elements, F callback) {
    this->printf_external("%d\n", length_of(elements));
    for (auto element : elements) { callback(element); }
  }

  void printf(const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    lsp_writer_->printf(format, arguments);
    va_end(arguments);
  }

  /// A version of 'printf' that keeps track of the data for the external sha1.
  /// Any data that represents a module's external representation needs to go
  /// through the sha1 so that we know when to recompute modules that depend on
  /// the current module.
  void printf_external(const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);

    // Calculate the size of the buffer required.
    va_list args_copy;
    va_copy(args_copy, arguments);
    int size = vsnprintf(NULL, 0, format, args_copy);
    va_end(args_copy);

    if (size < 0) FATAL("Failure to convert argument to string");

    // Allocate a buffer of the required size.
    char* buffer = unvoid_cast<char*>(malloc(size + 1));

    // Print to the buffer.
    vsnprintf(buffer, size + 1, format, arguments);
    va_end(arguments);

    printf("%s", buffer);
    sha1_.processBytes(buffer, size);
    free(buffer);
  }
};

template<typename T>
void Writer::print_toitdoc(T node) {
  auto toitdoc = toitdocs_.toitdoc_for(node);
  if (toitdoc.is_valid()) {
    ToitdocWriter toitdoc_writer(toitdoc, paths_, lsp_writer_);
    toitdoc_writer.write();
  } else {
    this->printf("0\n");
  }
}

void Writer::print_range(const Source::Range& range) {
  this->printf("%d\n", current_source_->offset_in_source(range.from()));
  this->printf("%d\n", current_source_->offset_in_source(range.to()));
}

void Writer::safe_print_symbol(Symbol symbol) {
  if (symbol.is_valid()) {
    this->printf("%s\n", symbol.c_str());
  } else {
    this->printf("\n");
  }
}

void Writer::safe_print_symbol_external(Symbol symbol) {
  if (symbol.is_valid()) {
    this->printf_external("%s\n", symbol.c_str());
  } else {
    this->printf_external("\n");
  }
}

void Writer::print_toplevel_ref(ir::Node* toplevel_element) {
  // Toplevel references are using an ID that is dependent on the current
  // analysis. That is, they are not stable across different runs.
  // As such, we can't just use the `print_external` as we do for other
  // external elements, but need to resolve it first, and use a stable
  // token for the external hasher.
  auto toplevel_id = toplevel_ids_.at(toplevel_element);
  this->printf("%d\n", toplevel_id);
  // Find the module that contains the toplevel element.
  // The toplevel_offets_ list contains the offset of each module in the
  // toplevel_ids_ list.
  auto next_higher = std::upper_bound(module_offsets_.begin(), module_offsets_.end(), toplevel_id);
  int index = next_higher - module_offsets_.begin();
  int module_id = index - 1;
  auto path = modules_[module_id]->unit()->absolute_path();
  sha1_.processBytes(path, strlen(path));
  sha1_.processBytes(&toplevel_id, sizeof(toplevel_id));
}

void Writer::print_type(ir::Type type) {
  if (!type.is_valid()) {
    // We would prefer not to have invalid types here, but globals are initially marked
    // with invalid types until their types are inferred in the type-check phase.
    // This 'if' clause is thus required as long as
    // https://github.com/toitlang/toit/issues/964 isn't fixed.
    this->printf_external("-1\n");
  } else if (type.is_any()) {
    this->printf_external("-1\n");
  } else if (type.is_none()) {
    this->printf_external("-2\n");
  } else if (type.is_class()) {
    print_toplevel_ref(type.klass());
  } else {
    UNREACHABLE();
  }
}

void Writer::print_field(ir::Field* field) {
  safe_print_symbol_external(field->name());
  print_range(field->range());
  print_range(field->outline_range());

  this->printf_external("%s\n", field->is_final() ? "final" : "mutable");
  this->printf_external("%s\n", field->is_deprecated() ? "deprecated" : "-");
  print_type(field->type());
  print_toitdoc(field);
}

void Writer::print_method(ir::Method* method) {
  if (method->name().is_valid()) {
    const char* name = method->name().c_str();
    if (method->is_setter()) {
      this->printf_external("%s=\n", name);
    } else if (is_operator_name(name)) {
      this->printf_external("operator %s\n", name);
    } else {
      this->printf_external("%s\n", method->name().c_str());
    }
  } else {
    ASSERT(!method->is_setter());
    safe_print_symbol_external(method->name());
  }
  print_range(method->range());
  print_range(method->outline_range());
  auto probe = toplevel_ids_.find(method);
  // The toplevel-id changes depending on how the file was analyzed.
  // Don't include it in the external representation.
  this->printf("%d\n", probe == toplevel_ids_.end() ? -1 : probe->second);
  switch (method->kind()) {
    case ir::Method::INSTANCE:
      if (method->is_FieldStub()) {
        ASSERT(!method->is_abstract());
        this->printf_external("field stub\n");
      } else if (method->is_abstract()) {
        this->printf_external("abstract\n");
      } else {
        this->printf_external("instance\n");
      }
      break;
    case ir::Method::CONSTRUCTOR:
      if (method->as_Constructor()->is_synthetic()) {
        this->printf_external("default constructor\n");
      } else {
        this->printf_external("constructor\n");
      }
      break;
    case ir::Method::GLOBAL_FUN: this->printf_external("global fun\n"); break;
    case ir::Method::GLOBAL_INITIALIZER: this->printf_external("global initializer\n"); break;
    case ir::Method::FACTORY: this->printf_external("factory\n"); break;
    case ir::Method::FIELD_INITIALIZER: UNREACHABLE();
  }
  this->printf_external("%s\n", method->is_deprecated() ? "deprecated" : "-");
  auto shape = method->resolution_shape();
  int max_unnamed = shape.max_unnamed_non_block() + shape.unnamed_block_count();
  bool has_implicit_this = method->is_instance() || method->is_constructor();
  this->printf_external("%d\n", method->parameters().length() - (has_implicit_this ? 1 : 0));
  for (int i = 0; i < method->parameters().length(); i++) {
    if (has_implicit_this && i == 0) continue;
    auto parameter = method->parameters()[i];
    safe_print_symbol_external(parameter->name());
    this->printf_external("%d\n", parameter->original_index());
    bool is_block = false;
    if (i < shape.min_unnamed_non_block()) {
      this->printf_external("required\n");
    } else if (i < shape.max_unnamed_non_block()) {
      this->printf_external("optional\n");
    } else if (i < shape.max_unnamed_non_block() + shape.unnamed_block_count()) {
      this->printf_external("required\n");
      is_block = true;
    } else if (shape.optional_names()[i - max_unnamed]) {
      this->printf_external("optional named\n");
    } else {
      this->printf_external("required named\n");
      is_block = i >= shape.max_arity() - shape.named_block_count();
    }
    if (parameter->has_default_value()) {
      // The default value is not included in the external representation.
      int length = parameter->default_value_range().length();
      auto pos = parameter->default_value_range().from();
      this->printf("%d\n", length);
      this->lsp_writer_->write(current_source_->text_at(pos), length);
    } else {
      this->printf("0\n");
    }
    if (is_block) {
      this->printf_external("[block]\n");
    } else {
      print_type(parameter->type());
    }
  }
  print_type(method->return_type());
  print_toitdoc(method);
}

void Writer::print_class(ir::Class* klass) {
  safe_print_symbol_external(klass->name());
  print_range(klass->range());
  print_range(klass->outline_range());
  // The toplevel ID changes depending on how the program was analyzed.
  // Don't include it in the external representation.
  this->printf("%d\n", toplevel_ids_.at(klass));
  const char* kind = "";  // Initialize with value to silence compiler warnings.
  switch (klass->kind()) {
    case ir::Class::CLASS:
      kind = "class";
      break;
    case ir::Class::MONITOR:
      kind = "class";
      break;
    case ir::Class::INTERFACE:
      kind = "interface";
      break;
    case ir::Class::MIXIN:
      kind = "mixin";
      break;
  }
  this->printf_external("%s\n", kind);
  this->printf_external("%s\n", klass->is_abstract() ? "abstract" : "-");
  this->printf_external("%s\n", klass->is_deprecated() ? "deprecated" : "-");
  if (klass->super() == null) {
    this->printf_external("-1\n");
  } else {
    this->print_toplevel_ref(klass->super());
  }
  print_list_external(klass->interfaces(), &Writer::print_toplevel_ref);
  print_list_external(klass->mixins(), &Writer::print_toplevel_ref);
  print_list_external(klass->statics()->nodes(), &Writer::print_method);
  print_list_external(klass->unnamed_constructors(), &Writer::print_method);
  print_list_external(klass->factories(), &Writer::print_method);
  print_list_external(klass->fields(), &Writer::print_field);
  print_list_external(klass->methods(), &Writer::print_method);
  print_toitdoc(klass);
}

void Writer::print_export(Symbol exported_id, const ResolutionEntry& entry) {
  safe_print_symbol(exported_id);
  switch (entry.kind()) {
    case ResolutionEntry::PREFIX:
      UNREACHABLE();
    case ResolutionEntry::AMBIGUOUS:
      this->printf_external("AMBIGUOUS\n");
      break;
    case ResolutionEntry::NODES:
      this->printf_external("NODES\n");
      break;
  }
  print_list_external(entry.nodes(), [&] (ir::Node* node) {
    ASSERT(node->is_Class() || node->is_Method());
    print_toplevel_ref(node);
  });
}

void Writer::print_dependencies(Module* module) {
  bool is_core = module == modules_[core_index_];
  ListBuilder<const char*> deps;
  if (is_core) {
    // Every module (except for core) implicitly imports core.
    deps.add(modules_[core_index_]->unit()->absolute_path());
  }
  auto unit = module->unit();
  for (auto import : unit->imports()) {
    if (import->unit()->absolute_path()[0] != '\0') {
      deps.add(import->unit()->absolute_path());
    }
  }
  print_list_external(deps.build(), [&] (const char* dep) {
    this->printf_external("%s\n", dep);
  });
}

void Writer::print_modules() {
  auto modules = modules_;
  this->printf("SUMMARY\n");
  // First print the number of classes in each module, so it's easier to
  // use them for typing and inheritance.
  int module_count = 0;
  for (auto module : modules) {
    // Ignore error modules. These are synthetic modules for
    // imports that couldn't be found.
    if (module->is_error_module()) continue;
    module_count++;
  }
  this->printf("%d\n", module_count);
  UnorderedMap<ir::Node*, int> toplevel_ids;
  List<int> module_offsets = ListBuilder<int>::allocate(modules.size());
  int toplevel_id = 0;
  int module_id = 0;
  for (auto module : modules) {
    module_offsets[module_id] = toplevel_id;
    // Ignore error modules.
    if (module->is_error_module()) continue;
    this->printf("%s\n", module->unit()->absolute_path());
    int total = module->classes().length() + module->methods().length() + module->globals().length();
    this->printf("%d\n", total);
    for (auto klass : module->classes()) {
      toplevel_ids[klass] = toplevel_id++;
    }
    for (auto method : module->methods()) {
      toplevel_ids[method] = toplevel_id++;
    }
    for (auto global : module->globals()) {
      toplevel_ids[global] = toplevel_id++;
    }
  }
  toplevel_ids_ = toplevel_ids;
  module_offsets_ = module_offsets;

  auto core_module = modules[core_index_];

  for (auto module : modules) {
    // Ignore error modules.
    if (module->is_error_module()) continue;

    print_module(module, core_module);
  }
}

void Writer::print_module(Module* module, Module* core_module) {

  current_source_ = module->unit()->source();

  // For simplicity repeat the module path and the class count.
  this->printf_external("%s\n", current_source_->absolute_path());

  print_dependencies(module);

  BufferedWriter buffered;
  auto old_writer = lsp_writer_;
  lsp_writer_ = &buffered;
  sha1_ = sha1::SHA1();

  this->printf_external("%s\n", module->is_deprecated() ? "deprecated" : "-");
  List<const char*> exported_modules;
  if (module->export_all()) {
    ListBuilder<const char*> builder;
    for (int i = 0; i < module->imported_modules().length(); i++) {
      auto import = module->imported_modules()[i];
      // The implicitly imported core module is always first. We discard those.
      // Other (explicit) imports of the core module are not discarded.
      if (i == 0 && import.module == core_module) continue;
      // Imports with shown identifiers are handled differently.
      if (!import.show_identifiers.is_empty()) continue;
      // Prefixed imports don't transitively export.
      if (import.prefix != null) continue;
      builder.add(import.module->unit()->absolute_path());
    }
    exported_modules = builder.build();
  }
  print_list_external(exported_modules, [&](const char* path) { printf_external("%s\n", path); });
  auto exported_identifiers_map = module->scope()->exported_identifiers_map();
  this->printf_external("%d\n", exported_identifiers_map.size());
  exported_identifiers_map.for_each([&](Symbol exported_id, ResolutionEntry entry) {
    print_export(exported_id, entry);
  });
  print_list_external(module->classes(), &Writer::print_class);
  print_list_external(module->methods(), &Writer::print_method);
  print_list_external(module->globals(), &Writer::print_method);

  print_toitdoc(module);

  lsp_writer_ = old_writer;

  sha1::SHA1::digest8_t digest;
  sha1_.getDigestBytes(digest);
  lsp_writer_->write(digest, sizeof(digest));
  int length = buffered.length();
  this->printf("%d\n", length);
  lsp_writer_->write(buffered.data(), buffered.length());
}

class ToitdocPathMappingCreator {
 public:
  /// Runs through the program and collects the toitdoc-paths to nodes that are referenced in toitdocs.
  UnorderedMap<ir::Node*, ToitdocPath> create(const std::vector<Module*>& modules,
                                              ToitdocRegistry toitdocs) {
    toitdocs.for_each([&](void* _, Toitdoc<ir::Node*> toitdoc) {
      for (auto ref : toitdoc.refs()) {
        if (ref == null) continue;

        // No need to collect parameter paths.
        if (ref->is_Parameter()) continue;
        ref_targets_.insert(ref);
      }
    });

    for (auto module : modules) {
      visit_container(ToitdocPath::Kind::CLASS, module, null, module->classes());
      visit_container(ToitdocPath::Kind::GLOBAL_METHOD, module, null, module->methods());
      visit_container(ToitdocPath::Kind::GLOBAL, module, null, module->globals());
      for (auto klass : module->classes()) {
        visit_container(ToitdocPath::Kind::STATIC_METHOD, module, klass, klass->statics()->nodes());
        visit_container(ToitdocPath::Kind::CONSTRUCTOR, module, klass, klass->unnamed_constructors());
        visit_container(ToitdocPath::Kind::FACTORY, module, klass, klass->factories());
        visit_container(ToitdocPath::Kind::FIELD, module, klass, klass->fields());
        visit_container(ToitdocPath::Kind::METHOD, module, klass, klass->methods());
      }
    }
    return mapping_;
  }

 private:
  Set<ir::Node*> ref_targets_;
  UnorderedMap<ir::Node*, ToitdocPath> mapping_;

  template<typename Container>
  void visit_container(ToitdocPath::Kind kind, Module* module, ir::Class* klass, Container list) {
    for (auto element : list) {
      if (ref_targets_.contains(element)) {
        mapping_[element] = {
          .kind = kind,
          .module = module,
          .klass = klass
        };
      }
    }
  }
};

}  // Anonymous namespace.


void emit_summary(const std::vector<Module*>& modules,
                  int core_index,
                  const ToitdocRegistry& toitdocs,
                  LspWriter* lsp_writer) {
  auto paths = ToitdocPathMappingCreator().create(modules, toitdocs);
  Writer writer(modules, toitdocs, core_index, paths, lsp_writer);
  writer.print_modules();
}

} // namespace toit::compiler
} // namespace toit
