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


NodeView ReferenceInfo::target() const {
  auto self = const_cast<ReferenceInfo*>(this);
  if (is_ReferenceClass()) return self->as_ReferenceClass()->target();
  if (is_ReferenceMethod()) return self->as_ReferenceMethod()->target();
  if (is_ReferenceGlobal()) return self->as_ReferenceGlobal()->target();
  if (is_ReferenceLocal()) return self->as_ReferenceLocal()->target();
  UNREACHABLE();
}

NodeView CallInfo::target() const {
  auto self = const_cast<CallInfo*>(this);
  if (is_CallStatic()) return self->as_CallStatic()->target();
  if (is_CallVirtual()) return self->as_CallVirtual()->target();
  if (is_CallBlock()) return self->as_CallBlock()->target();
  if (is_CallBuiltin()) return self->as_CallBuiltin()->target();
  UNREACHABLE();
}

bool MethodInfo::_parameters_have_correct_index(List<ParameterView> parameters) {
  for (int i = 0 ; i < parameters.length(); i++) {
    if (parameters[i]->index() != i) return false;
  }
  return true;
}


void Visitor::visit(NodeView node) { node->ast_node()->accept(this); }
void Visitor::visit(AstNode* node) { node->accept(this); }

void TraversingVisitor::visit_Program(ProgramView node) {
  for (auto klass: node->classes()) klass->accept(this);
  for (auto method: node->methods()) method->accept(this);
  for (auto global: node->globals()) global->accept(this);
}

void TraversingVisitor::visit_Class(ClassView node) {
  // By default we don't go through the constructors and factories, as they are
  // already being visited in `visit_Program`.
  for (auto field: node->fields()) field->accept(this);
  for (auto method: node->methods()) method->accept(this);
}

void TraversingVisitor::visit_Field(FieldView node) {}

void TraversingVisitor::visit_Method(MethodView node) {
  for (auto parameter : node->parameters()) parameter->accept(this);
  if (node->has_body()) node->body()->accept(this);
}

void TraversingVisitor::visit_MethodInstance(MethodInstanceView node) { visit_Method(node); }
void TraversingVisitor::visit_MonitorMethod(MonitorMethodView node) { visit_MethodInstance(node); }
void TraversingVisitor::visit_MethodStatic(MethodStaticView node) { visit_Method(node); }
void TraversingVisitor::visit_Constructor(ConstructorView node) { visit_Method(node); }
void TraversingVisitor::visit_Global(GlobalView node) { visit_Method(node); }
void TraversingVisitor::visit_AdapterStub(AdapterStubView node) { visit_Method(node); }
void TraversingVisitor::visit_MixinStub(MixinStubView node) { visit_Method(node); }
void TraversingVisitor::visit_IsInterfaceOrMixinStub(IsInterfaceOrMixinStubView node) { visit_Method(node); }
void TraversingVisitor::visit_FieldStub(FieldStubView node) { visit_Method(node); }

void TraversingVisitor::visit_Expression(ExpressionView node) { UNREACHABLE(); }

void TraversingVisitor::visit_Error(ErrorView node) {
  for (auto nested : node->nested()) {
    nested->accept(this);
  }
}

void TraversingVisitor::visit_Nop(NopView node) {}

void TraversingVisitor::visit_FieldStore(FieldStoreView node) {
  node->receiver()->accept(this);
  node->value()->accept(this);
}

void TraversingVisitor::visit_FieldLoad(FieldLoadView node) {
  node->receiver()->accept(this);
}

void TraversingVisitor::visit_Sequence(SequenceView node) {
  for (auto expr : node->expressions()) expr->accept(this);
}

void TraversingVisitor::visit_Builtin(BuiltinView node) {}

void TraversingVisitor::visit_TryFinally(TryFinallyView node) {
  node->body()->accept(this);
  for (auto parameter : node->handler_parameters()) parameter->accept(this);
  node->handler()->accept(this);
}

void TraversingVisitor::visit_If(IfView node) {
  node->condition()->accept(this);
  node->yes()->accept(this);
  node->no()->accept(this);
}

void TraversingVisitor::visit_Not(NotView node) {
  node->value()->accept(this);
}

void TraversingVisitor::visit_While(WhileView node) {
  node->condition()->accept(this);
  node->body()->accept(this);
  node->update()->accept(this);
}

void TraversingVisitor::visit_LoopBranch(LoopBranchView node) {}

void TraversingVisitor::visit_Code(CodeView node) {
  for (auto parameter : node->parameters()) parameter->accept(this);
  node->body()->accept(this);
}

void TraversingVisitor::visit_Reference(ReferenceView node) {}

void TraversingVisitor::visit_ReferenceClass(ReferenceClassView node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceMethod(ReferenceMethodView node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceLocal(ReferenceLocalView node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceBlock(ReferenceBlockView node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceGlobal(ReferenceGlobalView node) { visit_Reference(node); }

void TraversingVisitor::visit_Local(LocalView node) {}
void TraversingVisitor::visit_Parameter(ParameterView node) { visit_Local(node); }
void TraversingVisitor::visit_CapturedLocal(CapturedLocalView node) { visit_Parameter(node); }
void TraversingVisitor::visit_Block(BlockView node) { visit_Local(node); }

void TraversingVisitor::visit_Dot(DotView node) {
  node->receiver()->accept(this);
}

void TraversingVisitor::visit_LspSelectionDot(LspSelectionDotView node) { visit_Dot(node); }

void TraversingVisitor::visit_Super(SuperView node) {
  if (node->expression() != null) visit(node->expression());
}

void TraversingVisitor::visit_Call(CallView node) {
  node->target()->accept(this);
  for (auto argument : node->arguments()) argument->accept(this);
}

void TraversingVisitor::visit_CallStatic(CallStaticView node) { visit_Call(node); }
void TraversingVisitor::visit_Lambda(LambdaView node) { visit_CallStatic(node); }
void TraversingVisitor::visit_CallConstructor(CallConstructorView node) { visit_CallStatic(node); }
void TraversingVisitor::visit_CallVirtual(CallVirtualView node) { visit_Call(node); }
void TraversingVisitor::visit_CallBlock(CallBlockView node) { visit_Call(node); }
void TraversingVisitor::visit_CallBuiltin(CallBuiltinView node) { visit_Call(node); }

void TraversingVisitor::visit_Typecheck(TypecheckView node) {
  node->expression()->accept(this);
}

void TraversingVisitor::visit_Return(ReturnView node) {
  node->value()->accept(this);
}

void TraversingVisitor::visit_LogicalBinary(LogicalBinaryView node) {
  node->left()->accept(this);
  node->right()->accept(this);
}

void TraversingVisitor::visit_Assignment(AssignmentView node) {
  // Don't visit the LHS.
  // For an AssignmentGlobal, the LHS is a global (of type Method), and we
  //   don't want to visit other methods.
  node->right()->accept(this);
}

void TraversingVisitor::visit_AssignmentDefine(AssignmentDefineView node) { visit_Assignment(node); }
void TraversingVisitor::visit_AssignmentLocal(AssignmentLocalView node) { visit_Assignment(node); }
void TraversingVisitor::visit_AssignmentGlobal(AssignmentGlobalView node) { visit_Assignment(node); }

void TraversingVisitor::visit_Literal(LiteralView node) {}

void TraversingVisitor::visit_LiteralNull(LiteralNullView node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralUndefined(LiteralUndefinedView node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralInteger(LiteralIntegerView node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralFloat(LiteralFloatView node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralString(LiteralStringView node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralByteArray(LiteralByteArrayView node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralBoolean(LiteralBooleanView node) { visit_Literal(node); }

void TraversingVisitor::visit_PrimitiveInvocation(PrimitiveInvocationView node) {}

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

  void visit_Program(ProgramView node) {
    printf("-------- program --------\n");
    List<MethodView> methods = node->methods();
    for (int i = 0; i < methods.length(); i++) {
      if (i != 0) printf("\n");
      methods[i]->accept(this);
    }

    List<GlobalView> globals = node->globals();
    for (auto global : globals) {
      printf("Global %s:\n", global->name().c_str());
      global->accept(this);
    }

    for (auto klass : node->classes()) {
      klass->accept(this);
    }
    printf("-------------------------\n");
  }

  void visit_Class(ClassView node) {
    printf("\nClass %s", node->name().c_str());
    if (node->super() != null) {
      printf(" %s\n", node->super()->name().c_str());
    }
    indentation_++;
    for (auto field : node->fields()) visit(field);
    for (auto method : node->methods()) visit(method);
    indentation_--;
  }
  void visit_Field(FieldView node) {
    indent();
    printf("Field: %s\n", node->name().c_str());
  }

  void visit_Expression(ExpressionView node) { UNREACHABLE(); }

  void visit_Error(ErrorView node) {
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
  void visit_Reference(ReferenceView node) { UNREACHABLE(); }
  void visit_Literal(LiteralView node) { UNREACHABLE(); }

  void visit_Method(MethodView node) {
    indent();
    const char* kind = "";
    switch (node->kind()) {
      case MethodInfo::INSTANCE:
        if (node->is_abstract()) {
          kind = "abstract instance method";
        } else {
          kind = "instance method";
        }
        break;
      case MethodInfo::GLOBAL_FUN: kind = "static method"; break;
      case MethodInfo::FACTORY: kind = "factory"; break;
      case MethodInfo::CONSTRUCTOR: kind = "constructor"; break;
      case MethodInfo::GLOBAL_INITIALIZER: kind = "global initializer"; break;
      case MethodInfo::FIELD_INITIALIZER: kind = "field initializer"; break;
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

  void visit_MethodInstance(MethodInstanceView node) { visit_Method(node); }
  void visit_MonitorMethod(MonitorMethodView node) { visit_Method(node); }
  void visit_MethodStatic(MethodStaticView node) { visit_Method(node); }
  void visit_Constructor(ConstructorView node) { visit_Method(node); }
  void visit_Global(GlobalView node) { visit_Method(node); }
  void visit_AdapterStub(AdapterStubView node) { visit_Method(node); }
  void visit_MixinStub(MixinStubView node) { visit_Method(node); }
  void visit_FieldStub(FieldStubView node) { visit_Method(node); }

  void visit_IsInterfaceOrMixinStub(IsInterfaceOrMixinStubView node) {
    indent();
    printf("Is-interface stub: %s\n", node->name().c_str());
  }

  void visit_Code(CodeView node) {
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

  void visit_Nop(NopView node) {
    printf("NOP");
  }

  void visit_TryFinally(TryFinallyView node) {
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

  void visit_If(IfView node) {
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

  void visit_Not(NotView node) {
    printf("!");
    visit(node->value());
  }

  void visit_While(WhileView node) {
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

  void visit_LoopBranch(LoopBranchView node) {
    const char* kind = node->is_break() ? "break" : "continue";
    indent();
    if (node->block_depth() == 0) {
      printf("%s\n", kind);
    } else {
      printf("%s(%d)\n", kind, node->block_depth());
    }
  }

  void visit_LogicalBinary(LogicalBinaryView node) {
    visit(node->left());
    printf(" %s ", node->op() == LogicalBinaryInfo::AND ? "&&" : "||");
    visit(node->right());
  }

  void visit_Sequence(SequenceView node) {
    indent();
    printf("(sequence:\n");

    _visit_multiple(node->expressions());
    printf("\n");

    indent();
    printf(")\n");
  }

  void visit_FieldLoad(FieldLoadView node) {
    if (node->is_box_load()) {
      printf("(BoxRead (");
    } else {
      printf("(FieldRead (");
    }
    node->receiver()->accept(this);
    printf(").%s)", node->field()->name().c_str());
  }

  void visit_FieldStore(FieldStoreView node) {
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

  void visit_Super(SuperView node) {
    if (node->expression() == null) {
      printf("super");
    } else {
      printf("(super ");
      visit(node->expression());
      printf(")");
    }
  }

  void visit_Call(CallView node) {
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

  void visit_CallStatic(CallStaticView node) { visit_Call(node); }
  void visit_CallVirtual(CallVirtualView node) { visit_Call(node); }
  void visit_CallConstructor(CallConstructorView node) { visit_Call(node); }
  void visit_CallBuiltin(CallBuiltinView node) { visit_Builtin(node->target()); }

  void visit_Lambda(LambdaView node) {
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

  void visit_CallBlock(CallBlockView node) {
    printf("(Call Block ");
    node->target()->accept(this);
    printf(".call :\n");

    _visit_multiple(node->arguments());
    printf("\n");

    indent();
    printf(")");
  }

  void visit_Builtin(BuiltinView node) {
    const char* name = "unknown";
    switch (node->kind()) {
      case BuiltinInfo::THROW: name = "throw"; break;
      case BuiltinInfo::EXIT: name = "exit"; break;
      case BuiltinInfo::INVOKE_LAMBDA: name = "invoke_lambda"; break;
      case BuiltinInfo::YIELD: name = "yield"; break;
      case BuiltinInfo::RESET: name = "reset"; break;
      case BuiltinInfo::DEEP_SLEEP: name = "deep_sleep"; break;
      case BuiltinInfo::STORE_GLOBAL: name = "store_global"; break;
      case BuiltinInfo::LOAD_GLOBAL: name = "load_global"; break;
      case BuiltinInfo::INVOKE_INITIALIZER: name = "invoke_initializer"; break;
      case BuiltinInfo::GLOBAL_ID: name = "global_id"; break;
      case BuiltinInfo::IDENTICAL: name = "identical"; break;
    }
    printf("Builtin-%s", name);
  }

  void visit_ReferenceClass(ReferenceClassView node) {
    auto target = node->target();
    printf("%s", target->name().c_str());
  }

  void visit_ReferenceMethod(ReferenceMethodView node) {
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

  void visit_ReferenceLocal(ReferenceLocalView node) {
    if (node->block_depth() == 0) {
      printf("%s", node->target()->name().c_str());
    } else {
      printf("%s(%d)", node->target()->name().c_str(), node->block_depth());
    }
  }

  void visit_ReferenceBlock(ReferenceBlockView node) {
    printf("<BlockRef>");
  }

  void visit_ReferenceGlobal(ReferenceGlobalView node) {
    printf("%s%s", node->target()->name().c_str(), node->is_lazy() ? "" : "(eager)");
  }

  void visit_Local(LocalView node) {
    printf("%s", node->name().c_str());
  }

  void visit_Parameter(ParameterView node) { visit_Local(node); }
  void visit_CapturedLocal(CapturedLocalView node) { visit_Parameter(node); }

  void visit_Block(BlockView node) { visit_Local(node); }

  void visit_Dot(DotView node) {
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

  void visit_LspSelectionDot(LspSelectionDotView node) {
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

  void visit_PrimitiveInvocation(PrimitiveInvocationView node) {
    printf("{{%s:%s}}", node->module().c_str(), node->primitive().c_str());
  }

  void visit_Typecheck(TypecheckView node) {
    printf("(");
    visit(node->expression());
    printf(" %s %s%s",
           node->is_as_check() ? "as" : "is",
           node->type_name().c_str(),
           node->type().is_nullable() ? "?" : "");
    printf(")");
  }

  void visit_Return(ReturnView node) {
    printf("(return ");
    node->value()->accept(this);
    printf(")");
  }

  void visit_Assignment(AssignmentView node) {
    UNREACHABLE();
  }

  void visit_AssignmentLocal(AssignmentLocalView node) {
    if (node->block_depth() == 0) {
      printf("%s = ", node->local()->name().c_str());
    } else {
      printf("%s(%d) = ", node->local()->name().c_str(), node->block_depth());
    }
    node->right()->accept(this);
  }

  void visit_AssignmentGlobal(AssignmentGlobalView node) {
    printf("%s = ", node->global()->name().c_str());
    node->right()->accept(this);
  }

  void visit_AssignmentDefine(AssignmentDefineView node) {
    node->left()->accept(this);
    printf(" := ");
    node->right()->accept(this);
  }

  void visit_LiteralNull(LiteralNullView node) {
    printf("null");
  }

  void visit_LiteralUndefined(LiteralUndefinedView node) {
    printf("<undefined>");
  }

  void visit_LiteralInteger(LiteralIntegerView node) {
    printf("%" PRId64, node->value());
  }

  void visit_LiteralFloat(LiteralFloatView node) {
    printf("%g", node->value());
  }

  void visit_LiteralString(LiteralStringView node) {
    printf("%s", node->value());
  }

  void visit_LiteralByteArray(LiteralByteArrayView node) {
    printf("[");
    int length = node->data().length();
    for (int i = 0; i < length; i++) {
      printf("0x%x%s", node->data()[i], i == length - 1 ? "" : ", ");
    }
    printf("]");
  }

  void visit_LiteralBoolean(LiteralBooleanView node) {
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

void NodeInfo::print(bool use_resolution_shape) {
  Printer printer(use_resolution_shape);
  accept(&printer);
}

} // namespace toit::compiler::resolution
} // namespace toit::compiler
} // namespace toit
