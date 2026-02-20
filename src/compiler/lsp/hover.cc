// Copyright (C) 2026 Toitware ApS.
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

#include "hover.h"

#include "../ir.h"
#include "../sources.h"

namespace toit {
namespace compiler {

static std::string clean_toitdoc(const char* text, int length) {
  // Simple cleanup:
  // 1. Skip start `/**` or `/*` or `///` or `//`.
  // 2. Skip end `*/`.
  // 3. For each line, skip leading whitespace and `*` or `///` or `//`.

  std::string result;
  // We can't use stringstreams efficiently with length, so let's parse manually.
  const char* current = text;
  const char* end = text + length;

  while (current < end) {
    // Find end of line.
    const char* eol = current;
    while (eol < end && *eol != '\n') eol++;

    const char* line_start = current;
    const char* line_end = eol;

    // Skip leading whitespace.
    while (line_start < line_end && (*line_start == ' ' || *line_start == '\t')) line_start++;

    // Skip comment markers.
    if (line_start < line_end) {
      if (line_start + 3 <= line_end && strncmp(line_start, "/**", 3) == 0) {
        line_start += 3;
      } else if (line_start + 2 <= line_end && strncmp(line_start, "/*", 2) == 0) {
        line_start += 2;
      } else if (line_start + 3 <= line_end && strncmp(line_start, "///", 3) == 0) {
         line_start += 3;
      } else if (line_start + 2 <= line_end && strncmp(line_start, "//", 2) == 0) {
         line_start += 2;
      } else if (*line_start == '*') {
        line_start++;
      }
    }

    // Skip closing marker if present.
    // We only check for `*/` at the end of the line (ignoring trailing whitespace).
    const char* content_end = line_end;
    while (content_end > line_start && (content_end[-1] == ' ' || content_end[-1] == '\t' || content_end[-1] == '\r')) content_end--;
    if (content_end >= line_start + 2 && strncmp(content_end - 2, "*/", 2) == 0) {
      content_end -= 2;
    }

    // Skip (new) leading whitespace after marker.
    while (line_start < content_end && (*line_start == ' ' || *line_start == '\t')) line_start++;

    if (line_start < content_end) {
      if (!result.empty()) result += '\n';
      result.append(line_start, content_end - line_start);
    } else if (!result.empty()) {
      // Preserve empty lines if we already have content (paragraph separation).
      result += '\n';
    }
    
    current = eol + 1;
  }
  return result;
}

void HoverHandler::import_path(const char* path,
                               const char* segment,
                               bool is_first_segment,
                               const char* resolved,
                               const Package& package,
                               const PackageLock& package_lock,
                               Filesystem* filesystem) {
  if (resolved == null) return;
  std::string message = "Import: ";
  message += resolved;
  protocol()->hover()->emit(message.c_str());
}

void HoverHandler::class_interface_or_mixin(ast::Node* node,
                                            IterableScope* scope,
                                            ir::Class* holder,
                                            ir::Node* resolved,
                                            bool needs_interface,
                                            bool needs_mixin) {
  emit_hover(resolved, null);
}

void HoverHandler::type(ast::Node* node,
                        IterableScope* scope,
                        ResolutionEntry entry,
                        bool allow_none) {
  if (entry.is_class()) {
    emit_hover(entry.klass(), entry.klass()->name().c_str());
  }
}

void HoverHandler::call_virtual(ir::CallVirtual* node,
                                ir::Type type,
                                List<ir::Class*> classes) {
  Symbol selector = node->selector();
  
  if (type.is_none()) return;

  if (type.is_class()) {
    ir::Class* klass = type.klass();
    while (klass != null) {
      for (int i = -1; i < klass->mixins().length(); i++) {
        auto current = i == -1 ? klass : klass->mixins()[i];
        for (ir::MethodInstance* method : current->methods()) {
          if (method->name() == selector && method->resolution_shape().accepts(node->shape())) {
            emit_hover(method, null);
            return;
          }
        }
      }
      if (klass->super() == null && (klass->is_interface() || klass->is_mixin())) {
        klass = classes.length() > 0 ? classes[0] : null; // Usually Object
      } else {
        klass = klass->super();
      }
    }
  } else if (type.is_any()) {
    for (int i = 0; i < classes.length(); i++) {
      ir::Class* klass = classes[i];
      for (ir::MethodInstance* method : klass->methods()) {
        if (method->name() == selector && method->resolution_shape().accepts(node->shape())) {
          emit_hover(method, null);
          return;
        }
      }
    }
  }
}

void HoverHandler::call_prefixed(ast::Dot* node,
                                 ir::Node* resolved1,
                                 ir::Node* resolved2,
                                 List<ir::Node*> candidates,
                                 IterableScope* scope) {
  if (resolved1 != null && !resolved1->is_Error()) {
    emit_hover(resolved1, null);
  } else if (resolved2 != null && !resolved2->is_Error()) {
    emit_hover(resolved2, null);
  } else if (candidates.length() > 0) {
    emit_hover(candidates.first(), null);
  }
}

void HoverHandler::call_class(ast::Dot* node,
                              ir::Class* klass,
                              ir::Node* resolved1,
                              ir::Node* resolved2,
                              List<ir::Node*> candidates,
                              IterableScope* scope) {
  if (resolved1 != null && !resolved1->is_Error()) {
    emit_hover(resolved1, null);
  } else if (resolved2 != null && !resolved2->is_Error()) {
    emit_hover(resolved2, null);
  } else if (candidates.length() > 0) {
    emit_hover(candidates.first(), null);
  } else {
    emit_hover(klass, null);
  }
}

void HoverHandler::call_static(ast::Node* node,
                               ir::Node* resolved1,
                               ir::Node* resolved2,
                               List<ir::Node*> candidates,
                               IterableScope* scope,
                               ir::Method* surrounding) {
  if (resolved1 != null && !resolved1->is_Error()) {
    emit_hover(resolved1, null);
  } else if (resolved2 != null && !resolved2->is_Error()) {
    emit_hover(resolved2, null);
  } else if (candidates.length() > 0) {
    emit_hover(candidates.first(), null);
  }
}

void HoverHandler::call_block(ast::Dot* node, ir::Node* ir_receiver) {
  // No hover for blocks yet.
}

void HoverHandler::call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) {
  if (ir_call_target != null) {
    emit_hover(ir_call_target, null);
  }
}

void HoverHandler::call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                                  int module, int primitive, bool on_module) {
  // No hover for primitives.
}

void HoverHandler::field_storing_parameter(ast::Parameter* node,
                                           List<ir::Field*> fields,
                                           bool field_storing_is_allowed) {
  if (fields.length() == 1) {
    emit_hover(fields.first(), null);
  }
}

void HoverHandler::this_(ast::Identifier* node, ir::Class* enclosing_class, IterableScope* scope, ir::Method* surrounding) {
  emit_hover(enclosing_class, null);
}

void HoverHandler::show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  if (entry.kind() == ResolutionEntry::NODES) {
    if (entry.nodes().length() >= 1) {
      emit_hover(entry.nodes().first(), null);
    }
  } else if (entry.is_class()) {
    emit_hover(entry.klass(), null);
  }
}

void HoverHandler::expord(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) {
  if (entry.kind() == ResolutionEntry::NODES) {
    if (entry.nodes().length() >= 1) {
      emit_hover(entry.nodes().first(), null);
    }
  } else if (entry.is_class()) {
    emit_hover(entry.klass(), null);
  }
}

void HoverHandler::return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) {
  // No hover for labels.
}

void HoverHandler::toitdoc_ref(ast::Node* ref,
                               List<ir::Node*> candidates,
                               ToitdocScopeIterator* iterator,
                               bool is_signature) {
  if (candidates.length() != 1) return;
  emit_hover(candidates.first(), null);
}

void HoverHandler::emit_hover(ir::Node* node, const char* name) {
  if (node == null) return;

  if (node->is_Reference()) {
    node = node->as_Reference()->target();
  }

  Toitdoc<ir::Node*> toitdoc = toitdocs_->toitdoc_for(node);

  // Fallback to class toitdoc for constructors.
  if ((!toitdoc.is_valid() || toitdoc.contents() == null) && node->is_Constructor()) {
    toitdoc = toitdocs_->toitdoc_for(node->as_Constructor()->klass());
  }

  if (!toitdoc.is_valid()) {
    // Toitdoc not available yet — the target module may not have been
    // resolved. Cache the node for retry after full resolution.
    if (!has_emitted_ && deferred_node_ == null) {
      deferred_node_ = node;
    }
    return;
  }

  Source::Range range = toitdoc.range();
  if (!range.is_valid()) return;

  Source* source = source_manager_->source_for_position(range.from());
  if (source == null) return;

  int start = source->offset_in_source(range.from());
  int end = source->offset_in_source(range.to());
  int length = end - start;
  const char* text = reinterpret_cast<const char*>(source->text() + start);

  std::string cleaned = clean_toitdoc(text, length);
  protocol()->hover()->emit(cleaned.c_str());
  has_emitted_ = true;
}

void HoverHandler::finalize() {
  if (has_emitted_ || deferred_node_ == null) return;
  emit_hover(deferred_node_, null);
}

} // namespace compiler
} // namespace toit

