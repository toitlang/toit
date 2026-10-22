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

#include <functional>
#include <inttypes.h>

#include "resolution.h"

namespace toit {
namespace compiler {
namespace resolution {


View<Node> Reference::target() const {
  auto self = const_cast<Reference*>(this);
  if (is_ReferenceClass()) return self->as_ReferenceClass()->target();
  if (is_ReferenceMethod()) return self->as_ReferenceMethod()->target();
  if (is_ReferenceGlobal()) return self->as_ReferenceGlobal()->target();
  if (is_ReferenceLocal()) return self->as_ReferenceLocal()->target();
  UNREACHABLE();
}

View<Node> Call::target() const {
  auto self = const_cast<Call*>(this);
  if (is_CallStatic()) return self->as_CallStatic()->target();
  if (is_CallVirtual()) return self->as_CallVirtual()->target();
  if (is_CallBlock()) return self->as_CallBlock()->target();
  if (is_CallBuiltin()) return self->as_CallBuiltin()->target();
  UNREACHABLE();
}

bool Method::_parameters_have_correct_index(List<View<Parameter>> parameters) {
  for (int i = 0 ; i < parameters.length(); i++) {
    if (parameters[i]->index() != i) return false;
  }
  return true;
}


void Visitor::visit(View<Node> node) { node->ast_node()->accept(this); }
void Visitor::visit(AstNode* node) { node->accept(this); }

void TraversingVisitor::visit_Program(View<Program> node) {
  for (auto klass: node->classes()) klass->accept(this);
  for (auto method: node->methods()) method->accept(this);
  for (auto global: node->globals()) global->accept(this);
}

void TraversingVisitor::visit_Class(View<Class> node) {
  // By default we don't go through the constructors and factories, as they are
  // already being visited in `visit_Program`.
  for (auto field: node->fields()) field->accept(this);
  for (auto method: node->methods()) method->accept(this);
}

void TraversingVisitor::visit_Field(View<Field> node) {}

void TraversingVisitor::visit_Method(View<Method> node) {
  for (auto parameter : node->parameters()) parameter->accept(this);
  if (node->has_body()) node->body()->accept(this);
}

void TraversingVisitor::visit_MethodInstance(View<MethodInstance> node) { visit_Method(node); }
void TraversingVisitor::visit_MonitorMethod(View<MonitorMethod> node) { visit_MethodInstance(node); }
void TraversingVisitor::visit_MethodStatic(View<MethodStatic> node) { visit_Method(node); }
void TraversingVisitor::visit_Constructor(View<Constructor> node) { visit_Method(node); }
void TraversingVisitor::visit_Global(View<Global> node) { visit_Method(node); }
void TraversingVisitor::visit_AdapterStub(View<AdapterStub> node) { visit_Method(node); }
void TraversingVisitor::visit_MixinStub(View<MixinStub> node) { visit_Method(node); }
void TraversingVisitor::visit_IsInterfaceOrMixinStub(View<IsInterfaceOrMixinStub> node) { visit_Method(node); }
void TraversingVisitor::visit_FieldStub(View<FieldStub> node) { visit_Method(node); }

void TraversingVisitor::visit_Expression(View<Expression> node) { UNREACHABLE(); }

void TraversingVisitor::visit_Error(View<Error> node) {
  for (auto nested : node->nested()) {
    nested->accept(this);
  }
}

void TraversingVisitor::visit_Nop(View<Nop> node) {}

void TraversingVisitor::visit_FieldStore(View<FieldStore> node) {
  node->receiver()->accept(this);
  node->value()->accept(this);
}

void TraversingVisitor::visit_FieldLoad(View<FieldLoad> node) {
  node->receiver()->accept(this);
}

void TraversingVisitor::visit_Sequence(View<Sequence> node) {
  for (auto expr : node->expressions()) expr->accept(this);
}

void TraversingVisitor::visit_Builtin(View<Builtin> node) {}

void TraversingVisitor::visit_TryFinally(View<TryFinally> node) {
  node->body()->accept(this);
  for (auto parameter : node->handler_parameters()) parameter->accept(this);
  node->handler()->accept(this);
}

void TraversingVisitor::visit_If(View<If> node) {
  node->condition()->accept(this);
  node->yes()->accept(this);
  node->no()->accept(this);
}

void TraversingVisitor::visit_Not(View<Not> node) {
  node->value()->accept(this);
}

void TraversingVisitor::visit_While(View<While> node) {
  node->condition()->accept(this);
  node->body()->accept(this);
  node->update()->accept(this);
}

void TraversingVisitor::visit_LoopBranch(View<LoopBranch> node) {}

void TraversingVisitor::visit_Code(View<Code> node) {
  for (auto parameter : node->parameters()) parameter->accept(this);
  node->body()->accept(this);
}

void TraversingVisitor::visit_Reference(View<Reference> node) {}

void TraversingVisitor::visit_ReferenceClass(View<ReferenceClass> node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceMethod(View<ReferenceMethod> node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceLocal(View<ReferenceLocal> node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceBlock(View<ReferenceBlock> node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceGlobal(View<ReferenceGlobal> node) { visit_Reference(node); }

void TraversingVisitor::visit_Local(View<Local> node) {}
void TraversingVisitor::visit_Parameter(View<Parameter> node) { visit_Local(node); }
void TraversingVisitor::visit_CapturedLocal(View<CapturedLocal> node) { visit_Parameter(node); }
void TraversingVisitor::visit_Block(View<Block> node) { visit_Local(node); }

void TraversingVisitor::visit_Dot(View<Dot> node) {
  node->receiver()->accept(this);
}

void TraversingVisitor::visit_LspSelectionDot(View<LspSelectionDot> node) { visit_Dot(node); }

void TraversingVisitor::visit_Super(View<Super> node) {
  if (node->expression() != null) visit(node->expression());
}

void TraversingVisitor::visit_Call(View<Call> node) {
  node->target()->accept(this);
  for (auto argument : node->arguments()) argument->accept(this);
}

void TraversingVisitor::visit_CallStatic(View<CallStatic> node) { visit_Call(node); }
void TraversingVisitor::visit_Lambda(View<Lambda> node) { visit_CallStatic(node); }
void TraversingVisitor::visit_CallConstructor(View<CallConstructor> node) { visit_CallStatic(node); }
void TraversingVisitor::visit_CallVirtual(View<CallVirtual> node) { visit_Call(node); }
void TraversingVisitor::visit_CallBlock(View<CallBlock> node) { visit_Call(node); }
void TraversingVisitor::visit_CallBuiltin(View<CallBuiltin> node) { visit_Call(node); }

void TraversingVisitor::visit_Typecheck(View<Typecheck> node) {
  node->expression()->accept(this);
}

void TraversingVisitor::visit_Return(View<Return> node) {
  node->value()->accept(this);
}

void TraversingVisitor::visit_LogicalBinary(View<LogicalBinary> node) {
  node->left()->accept(this);
  node->right()->accept(this);
}

void TraversingVisitor::visit_Assignment(View<Assignment> node) {
  // Don't visit the LHS.
  // For an AssignmentGlobal, the LHS is a global (of type Method), and we
  //   don't want to visit other methods.
  node->right()->accept(this);
}

void TraversingVisitor::visit_AssignmentDefine(View<AssignmentDefine> node) { visit_Assignment(node); }
void TraversingVisitor::visit_AssignmentLocal(View<AssignmentLocal> node) { visit_Assignment(node); }
void TraversingVisitor::visit_AssignmentGlobal(View<AssignmentGlobal> node) { visit_Assignment(node); }

void TraversingVisitor::visit_Literal(View<Literal> node) {}

void TraversingVisitor::visit_LiteralNull(View<LiteralNull> node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralUndefined(View<LiteralUndefined> node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralInteger(View<LiteralInteger> node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralFloat(View<LiteralFloat> node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralString(View<LiteralString> node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralByteArray(View<LiteralByteArray> node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralBoolean(View<LiteralBoolean> node) { visit_Literal(node); }

void TraversingVisitor::visit_PrimitiveInvocation(View<PrimitiveInvocation> node) {}

class Printer : public Visitor {
 public:
  explicit Printer(bool use_resolution_shape)
      : indentation_(0), use_resolution_shape_(use_resolution_shape) {}

  template<typename T>
  void _visit_multiple(List<T> nodes, char separation = '\n') {
    bool should_indent = separation == '\n';
    if (should_indent) indentation_++;
    for (int i = 0; i < nodes.length(); i++) {
      if (should_indent) {
        indent();
      } else if (i != 0) {
        printf("%c", separation);
      }
      nodes[i]->accept(this);
    }
    if (should_indent) indentation_--;
  }

  void visit_Program(View<Program> node) {
    printf("-------- program --------\n");
    List<View<Method>> methods = node->methods();
    for (int i = 0; i < methods.length(); i++) {
      if (i != 0) printf("\n");
      methods[i]->accept(this);
    }

    List<View<Global>> globals = node->globals();
    for (auto global : globals) {
      printf("Global %s:\n", global->name().c_str());
      global->accept(this);
    }

    for (auto klass : node->classes()) {
      klass->accept(this);
    }
    printf("-------------------------\n");
  }

  void visit_Class(View<Class> node) {
    printf("\nClass %s", node->name().c_str());
    if (node->super() != null) {
      printf(" %s\n", node->super()->name().c_str());
    }
    indentation_++;
    for (auto field : node->fields()) visit(field);
    for (auto method : node->methods()) visit(method);
    indentation_--;
  }
  void visit_Field(View<Field> node) {
    indent();
    printf("Field: %s\n", node->name().c_str());
  }

  void visit_Expression(View<Expression> node) { UNREACHABLE(); }

  void visit_Error(View<Error> node) {
    indent();
    printf("(ERROR:");
    indentation_++;
    for (auto nested : node->nested()) {
      printf("\n");
      indent();
      visit(nested);
    }
    indentation_--;
    printf("\n");
    indent();
    printf(")");
  }
  void visit_Reference(View<Reference> node) { UNREACHABLE(); }
  void visit_Literal(View<Literal> node) { UNREACHABLE(); }

  void visit_Method(View<Method> node) {
    indent();
    const char* kind = "";
    switch (node->kind()) {
      case Method::INSTANCE:
        if (node->is_abstract()) {
          kind = "abstract instance method";
        } else {
          kind = "instance method";
        }
        break;
      case Method::GLOBAL_FUN: kind = "static method"; break;
      case Method::FACTORY: kind = "factory"; break;
      case Method::CONSTRUCTOR: kind = "constructor"; break;
      case Method::GLOBAL_INITIALIZER: kind = "global initializer"; break;
      case Method::FIELD_INITIALIZER: kind = "field initializer"; break;
    }

    auto parameters = node->parameters();
    int optional_unnamed = 0;
    List<Symbol> names;
    std::vector<bool> optional_named;
    int unnamed_block_count = 0;
    int named_block_count;
    if (use_resolution_shape_) {
      auto shape = node->resolution_shape();
      optional_unnamed = shape.max_unnamed_non_block() - shape.min_unnamed_non_block();
      names = shape.names();
      optional_named = shape.optional_names();
      unnamed_block_count = shape.unnamed_block_count();
      named_block_count = shape.named_block_count();
    } else {
      auto shape = node->plain_shape();
      names = shape.names();
      for (int i = 0; i < names.length(); i++) optional_named.push_back(false);
      unnamed_block_count = shape.unnamed_block_count();
      named_block_count = shape.named_block_count();
    }
    int unnamed_count = parameters.length() - names.length();
    printf("(%s:%s%s (", kind, node->name().c_str(), node->is_setter() ? "=" : "");
    bool is_first = true;
    for (int i = 0; i < parameters.length(); i++) {
      auto parameter = parameters[i];
      if (is_first) {
        is_first = false;
      } else {
        printf(",");
      }
      bool is_named = i >= unnamed_count;
      if (is_named) {
        int name_index = i - unnamed_count;
        bool is_block = name_index >= (names.length() - named_block_count);
        bool is_optional = optional_named[name_index];
        printf("[--%s]%s%s%s",
               names[name_index].c_str(),
               is_optional ? "?" : "",
               is_block ? ":" : "",
               parameter->name().c_str());
      } else {
        bool is_block = (i >= unnamed_count - unnamed_block_count);
        bool is_optional = !is_block &&
            (i >= unnamed_count - unnamed_block_count - optional_unnamed);
        printf("%s%s%s",
               is_optional ? "?" : "",
               is_block ? ":" : "",
               parameter->name().c_str());
      }
    }
    printf(")");

    indentation_++;
    if (node->has_body()) {
      visit(node->body());
    }
    indentation_--;

    indent();
    printf(")\n");
  }

  void visit_MethodInstance(View<MethodInstance> node) { visit_Method(node); }
  void visit_MonitorMethod(View<MonitorMethod> node) { visit_Method(node); }
  void visit_MethodStatic(View<MethodStatic> node) { visit_Method(node); }
  void visit_Constructor(View<Constructor> node) { visit_Method(node); }
  void visit_Global(View<Global> node) { visit_Method(node); }
  void visit_AdapterStub(View<AdapterStub> node) { visit_Method(node); }
  void visit_MixinStub(View<MixinStub> node) { visit_Method(node); }
  void visit_FieldStub(View<FieldStub> node) { visit_Method(node); }

  void visit_IsInterfaceOrMixinStub(View<IsInterfaceOrMixinStub> node) {
    indent();
    printf("Is-interface stub: %s\n", node->name().c_str());
  }

  void visit_Code(View<Code> node) {
    indent();
    printf("(code:");
    auto parameters = node->parameters();
    if (!parameters.is_empty()) {
      printf("|");
      _visit_multiple(parameters, ' ');
      printf("|");
    }
    printf("\n");
    indentation_++;

    visit(node->body());

    indentation_--;
    indent();
    printf(")\n");
  }

  void visit_Nop(View<Nop> node) {
    printf("NOP");
  }

  void visit_TryFinally(View<TryFinally> node) {
    indent();
    printf("(try:\n");
    indentation_++;
    visit(node->body());
    indentation_--;
    indent();
    printf("finally:");
    if (!node->handler_parameters().is_empty()) {
      printf("|");
      _visit_multiple(node->handler_parameters(), ' ');
      printf("|");
    }
    printf("\n");
    indentation_++;
    visit(node->handler());
    indentation_--;
    indent();
    printf(")\n");
  }

  void visit_If(View<If> node) {
    indent();
    printf("(if ");
    visit(node->condition());
    printf(":\n");

    indentation_++;
    visit(node->yes());
    indentation_--;

    indent();
    printf("else:");

    indentation_++;
    visit(node->no());
    indentation_--;

    indent();
    printf(")\n");
  }

  void visit_Not(View<Not> node) {
    printf("!");
    visit(node->value());
  }

  void visit_While(View<While> node) {
    indent();
    printf("(while ");
    visit(node->condition());
    printf(":\n");

    indentation_++;
    visit(node->body());
    indentation_--;

    printf("update:\n");

    indentation_++;
    visit(node->update());
    indentation_--;

    indent();
    printf(")\n");
  }

  void visit_LoopBranch(View<LoopBranch> node) {
    const char* kind = node->is_break() ? "break" : "continue";
    indent();
    if (node->block_depth() == 0) {
      printf("%s\n", kind);
    } else {
      printf("%s(%d)\n", kind, node->block_depth());
    }
  }

  void visit_LogicalBinary(View<LogicalBinary> node) {
    visit(node->left());
    printf(" %s ", node->op() == LogicalBinary::AND ? "&&" : "||");
    visit(node->right());
  }

  void visit_Sequence(View<Sequence> node) {
    indent();
    printf("(sequence:\n");

    _visit_multiple(node->expressions());
    printf("\n");

    indent();
    printf(")\n");
  }

  void visit_FieldLoad(View<FieldLoad> node) {
    if (node->is_box_load()) {
      printf("(BoxRead (");
    } else {
      printf("(FieldRead (");
    }
    node->receiver()->accept(this);
    printf(").%s)", node->field()->name().c_str());
  }

  void visit_FieldStore(View<FieldStore> node) {
    if (node->is_box_store()) {
      printf("(BoxStore (");
    } else {
      printf("(FieldStore (");
    }
    node->receiver()->accept(this);
    printf(").%s = \n", node->field()->name().c_str());
    node->value()->accept(this);
    printf(")");
  }

  void visit_Super(View<Super> node) {
    if (node->expression() == null) {
      printf("super");
    } else {
      printf("(super ");
      visit(node->expression());
      printf(")");
    }
  }

  void visit_Call(View<Call> node) {
    printf("(Call (%d,%d,%d",
           node->shape().arity(),
           node->shape().total_block_count(),
           node->shape().named_block_count());
    auto names = node->shape().names();
    for (auto name : names) {
      printf(", %s", name.c_str());
    }
    printf(") ");
    node->target()->accept(this);
    printf(":\n");

    _visit_multiple(node->arguments());
    printf("\n");

    indent();
    printf(")");
  }

  void visit_CallStatic(View<CallStatic> node) { visit_Call(node); }
  void visit_CallVirtual(View<CallVirtual> node) { visit_Call(node); }
  void visit_CallConstructor(View<CallConstructor> node) { visit_Call(node); }
  void visit_CallBuiltin(View<CallBuiltin> node) { visit_Builtin(node->target()); }

  void visit_Lambda(View<Lambda> node) {
    printf("(Lamba:\n");
    indentation_++;
    visit(node->arguments()[1]);
    indentation_--;
    indent();
    printf("-- Body:\n");
    indentation_++;
    visit(node->code());
    indentation_--;

    indent();
    printf(")");
  }

  void visit_CallBlock(View<CallBlock> node) {
    printf("(Call Block ");
    node->target()->accept(this);
    printf(".call :\n");

    _visit_multiple(node->arguments());
    printf("\n");

    indent();
    printf(")");
  }

  void visit_Builtin(View<Builtin> node) {
    const char* name = "unknown";
    switch (node->kind()) {
      case Builtin::THROW: name = "throw"; break;
      case Builtin::EXIT: name = "exit"; break;
      case Builtin::INVOKE_LAMBDA: name = "invoke_lambda"; break;
      case Builtin::YIELD: name = "yield"; break;
      case Builtin::RESET: name = "reset"; break;
      case Builtin::DEEP_SLEEP: name = "deep_sleep"; break;
      case Builtin::STORE_GLOBAL: name = "store_global"; break;
      case Builtin::LOAD_GLOBAL: name = "load_global"; break;
      case Builtin::INVOKE_INITIALIZER: name = "invoke_initializer"; break;
      case Builtin::GLOBAL_ID: name = "global_id"; break;
      case Builtin::IDENTICAL: name = "identical"; break;
    }
    printf("Builtin-%s", name);
  }

  void visit_ReferenceClass(View<ReferenceClass> node) {
    auto target = node->target();
    printf("%s", target->name().c_str());
  }

  void visit_ReferenceMethod(View<ReferenceMethod> node) {
    auto target = node->target();
    int arity;
    int block_count;
    if (use_resolution_shape_) {
      arity = target->resolution_shape().max_arity();
      block_count = target->resolution_shape().total_block_count();
    } else {
      arity = target->plain_shape().arity();
      block_count = target->plain_shape().total_block_count();
    }
    printf("%s (%d, %d)", target->name().c_str(), arity, block_count);
  }

  void visit_ReferenceLocal(View<ReferenceLocal> node) {
    if (node->block_depth() == 0) {
      printf("%s", node->target()->name().c_str());
    } else {
      printf("%s(%d)", node->target()->name().c_str(), node->block_depth());
    }
  }

  void visit_ReferenceBlock(View<ReferenceBlock> node) {
    printf("<BlockRef>");
  }

  void visit_ReferenceGlobal(View<ReferenceGlobal> node) {
    printf("%s%s", node->target()->name().c_str(), node->is_lazy() ? "" : "(eager)");
  }

  void visit_Local(View<Local> node) {
    printf("%s", node->name().c_str());
  }

  void visit_Parameter(View<Parameter> node) { visit_Local(node); }
  void visit_CapturedLocal(View<CapturedLocal> node) { visit_Parameter(node); }

  void visit_Block(View<Block> node) { visit_Local(node); }

  void visit_Dot(View<Dot> node) {
    auto receiver = node->receiver();
    if (!receiver->is_Local()) {
      printf("(");
    }
    receiver->accept(this);
    if (!receiver->is_Local()) {
      printf(")");
    }
    printf(".%s", node->selector().c_str());
  }

  void visit_LspSelectionDot(View<LspSelectionDot> node) {
    auto receiver = node->receiver();
    if (!receiver->is_Local()) {
      printf("(");
    }
    receiver->accept(this);
    if (!receiver->is_Local()) {
      printf(")");
    }
    printf(".<Target: %s>", node->selector().c_str());
  }

  void visit_PrimitiveInvocation(View<PrimitiveInvocation> node) {
    printf("{{%s:%s}}", node->module().c_str(), node->primitive().c_str());
  }

  void visit_Typecheck(View<Typecheck> node) {
    printf("(");
    visit(node->expression());
    printf(" %s %s%s",
           node->is_as_check() ? "as" : "is",
           node->type_name().c_str(),
           node->type().is_nullable() ? "?" : "");
    printf(")");
  }

  void visit_Return(View<Return> node) {
    printf("(return ");
    node->value()->accept(this);
    printf(")");
  }

  void visit_Assignment(View<Assignment> node) {
    UNREACHABLE();
  }

  void visit_AssignmentLocal(View<AssignmentLocal> node) {
    if (node->block_depth() == 0) {
      printf("%s = ", node->local()->name().c_str());
    } else {
      printf("%s(%d) = ", node->local()->name().c_str(), node->block_depth());
    }
    node->right()->accept(this);
  }

  void visit_AssignmentGlobal(View<AssignmentGlobal> node) {
    printf("%s = ", node->global()->name().c_str());
    node->right()->accept(this);
  }

  void visit_AssignmentDefine(View<AssignmentDefine> node) {
    node->left()->accept(this);
    printf(" := ");
    node->right()->accept(this);
  }

  void visit_LiteralNull(View<LiteralNull> node) {
    printf("null");
  }

  void visit_LiteralUndefined(View<LiteralUndefined> node) {
    printf("<undefined>");
  }

  void visit_LiteralInteger(View<LiteralInteger> node) {
    printf("%" PRId64, node->value());
  }

  void visit_LiteralFloat(View<LiteralFloat> node) {
    printf("%g", node->value());
  }

  void visit_LiteralString(View<LiteralString> node) {
    printf("%s", node->value());
  }

  void visit_LiteralByteArray(View<LiteralByteArray> node) {
    printf("[");
    int length = node->data().length();
    for (int i = 0; i < length; i++) {
      printf("0x%x%s", node->data()[i], i == length - 1 ? "" : ", ");
    }
    printf("]");
  }

  void visit_LiteralBoolean(View<LiteralBoolean> node) {
    printf("%s", node->value() ? "true" : "false");
  }

 private:
  int indentation_;
  bool use_resolution_shape_;

  void indent() {
    for (int i = 0; i < indentation_; i++) {
      printf("  ");
    }
  }
};

void Node::print(bool use_resolution_shape) {
  Printer printer(use_resolution_shape);
  accept(&printer);
}

} // namespace toit::compiler::resolution
} // namespace toit::compiler
} // namespace toit
