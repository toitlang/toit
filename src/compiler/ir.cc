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

#include "ir.h"

namespace toit {
namespace compiler {
namespace ir {


bool Method::_parameters_have_correct_index(List<Parameter*> parameters) {
  for (int i = 0 ; i < parameters.length(); i++) {
    if (parameters[i]->index() != i) return false;
  }
  return true;
}


void Visitor::visit(Node* node) { node->accept(this); }

void TraversingVisitor::visit_Program(Program* node) {
  for (auto klass: node->classes()) klass->accept(this);
  for (auto method: node->methods()) method->accept(this);
  for (auto global: node->globals()) global->accept(this);
}

void TraversingVisitor::visit_Class(Class* node) {
  // By default we don't go through the constructors and factories, as they are
  // already being visited in `visit_Program`.
  for (auto field: node->fields()) field->accept(this);
  for (auto method: node->methods()) method->accept(this);
}

void TraversingVisitor::visit_Field(Field* node) { }

void TraversingVisitor::visit_Method(Method* node) {
  for (auto parameter : node->parameters()) parameter->accept(this);
  if (node->has_body()) node->body()->accept(this);
}

void TraversingVisitor::visit_MethodInstance(MethodInstance* node) { visit_Method(node); }
void TraversingVisitor::visit_MonitorMethod(MonitorMethod* node) { visit_MethodInstance(node); }
void TraversingVisitor::visit_MethodStatic(MethodStatic* node) { visit_Method(node); }
void TraversingVisitor::visit_Constructor(Constructor* node) { visit_Method(node); }
void TraversingVisitor::visit_Global(Global* node) { visit_Method(node); }
void TraversingVisitor::visit_AdapterStub(AdapterStub* node) { visit_Method(node); }
void TraversingVisitor::visit_IsInterfaceStub(IsInterfaceStub* node) { visit_Method(node); }
void TraversingVisitor::visit_FieldStub(FieldStub* node) { visit_Method(node); }

void TraversingVisitor::visit_Expression(Expression* node) { UNREACHABLE(); }

void TraversingVisitor::visit_Error(Error* node) {
  for (auto nested : node->nested()) {
    nested->accept(this);
  }
}

void TraversingVisitor::visit_Nop(Nop* node) { }

void TraversingVisitor::visit_FieldStore(FieldStore* node) {
  node->receiver()->accept(this);
  node->value()->accept(this);
}

void TraversingVisitor::visit_FieldLoad(FieldLoad* node) {
  node->receiver()->accept(this);
}

void TraversingVisitor::visit_Sequence(Sequence* node) {
  for (auto expr : node->expressions()) expr->accept(this);
}

void TraversingVisitor::visit_Builtin(Builtin* node) { }

void TraversingVisitor::visit_TryFinally(TryFinally* node) {
  node->body()->accept(this);
  for (auto parameter : node->handler_parameters()) parameter->accept(this);
  node->handler()->accept(this);
}

void TraversingVisitor::visit_If(If* node) {
  node->condition()->accept(this);
  node->yes()->accept(this);
  node->no()->accept(this);
}

void TraversingVisitor::visit_Not(Not* node) {
  node->value()->accept(this);
}

void TraversingVisitor::visit_While(While* node) {
  node->condition()->accept(this);
  node->body()->accept(this);
  node->update()->accept(this);
}

void TraversingVisitor::visit_LoopBranch(LoopBranch* node) { }

void TraversingVisitor::visit_Code(Code* node) {
  for (auto parameter : node->parameters()) parameter->accept(this);
  node->body()->accept(this);
}

void TraversingVisitor::visit_Reference(Reference* node) { }

void TraversingVisitor::visit_ReferenceClass(ReferenceClass* node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceMethod(ReferenceMethod* node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceLocal(ReferenceLocal* node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceBlock(ReferenceBlock* node) { visit_Reference(node); }
void TraversingVisitor::visit_ReferenceGlobal(ReferenceGlobal* node) { visit_Reference(node); }

void TraversingVisitor::visit_Local(Local* node) { }
void TraversingVisitor::visit_Parameter(Parameter* node) { visit_Local(node); }
void TraversingVisitor::visit_CapturedLocal(CapturedLocal* node) { visit_Parameter(node); }
void TraversingVisitor::visit_Block(Block* node) { visit_Local(node); }

void TraversingVisitor::visit_Dot(Dot* node) {
  node->receiver()->accept(this);
}

void TraversingVisitor::visit_LspSelectionDot(LspSelectionDot* node) { visit_Dot(node); }

void TraversingVisitor::visit_Super(Super* node) {
  if (node->expression() != null) visit(node->expression());
}

void TraversingVisitor::visit_Call(Call* node) {
  node->target()->accept(this);
  for (auto argument : node->arguments()) argument->accept(this);
}

void TraversingVisitor::visit_CallStatic(CallStatic* node) { visit_Call(node); }
void TraversingVisitor::visit_Lambda(Lambda* node) { visit_CallStatic(node); }
void TraversingVisitor::visit_CallConstructor(CallConstructor* node) { visit_Call(node); }
void TraversingVisitor::visit_CallVirtual(CallVirtual* node) { visit_Call(node); }
void TraversingVisitor::visit_CallBlock(CallBlock* node) { visit_Call(node); }
void TraversingVisitor::visit_CallBuiltin(CallBuiltin* node) { visit_Call(node); }

void TraversingVisitor::visit_Typecheck(Typecheck* node) {
  node->expression()->accept(this);
}

void TraversingVisitor::visit_Return(Return* node) {
  node->value()->accept(this);
}

void TraversingVisitor::visit_LogicalBinary(LogicalBinary* node) {
  node->left()->accept(this);
  node->right()->accept(this);
}

void TraversingVisitor::visit_Assignment(Assignment* node) {
  // Don't visit the LHS.
  // For an AssignmentGlobal, the LHS is a global (of type Method), and we
  //   don't want to visit other methods.
  node->right()->accept(this);
}

void TraversingVisitor::visit_AssignmentDefine(AssignmentDefine* node) { visit_Assignment(node); }
void TraversingVisitor::visit_AssignmentLocal(AssignmentLocal* node) { visit_Assignment(node); }
void TraversingVisitor::visit_AssignmentGlobal(AssignmentGlobal* node) { visit_Assignment(node); }

void TraversingVisitor::visit_Literal(Literal* node) { }

void TraversingVisitor::visit_LiteralNull(LiteralNull* node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralUndefined(LiteralUndefined* node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralInteger(LiteralInteger* node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralFloat(LiteralFloat* node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralString(LiteralString* node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralByteArray(LiteralByteArray* node) { visit_Literal(node); }
void TraversingVisitor::visit_LiteralBoolean(LiteralBoolean* node) { visit_Literal(node); }

void TraversingVisitor::visit_PrimitiveInvocation(PrimitiveInvocation* node) { }

Node* ReplacingVisitor::visit(Node* node) {
  return node->accept(this);
}

Node* ReplacingVisitor::visit_Program(Program* node) {
  auto classes = node->classes();
  for (int i = 0; i < classes.length(); i++) {
    auto klass = classes[i];
    auto new_class = klass->accept(this);
    ASSERT(new_class->is_Class());
    classes[i] = new_class->as_Class();
  }
  auto methods = node->methods();
  for (int i = 0; i < methods.length(); i++) {
    auto method = methods[i];
    auto new_method = method->accept(this);
    ASSERT(new_method->is_Method());
    methods[i] = new_method->as_Method();
  }
  auto globals = node->globals();
  for (int i = 0; i < globals.length(); i++) {
    auto global = globals[i];
    auto new_global = global->accept(this);
    ASSERT(new_global->is_Global());
    globals[i] = new_global->as_Global();
  }
  return node;
}

Node* ReplacingVisitor::visit_Class(Class* node) {
  auto methods = node->methods();
  for (int i = 0; i < methods.length(); i++) {
    auto method = methods[i];
    auto new_method = method->accept(this);
    ASSERT(new_method->is_MethodInstance());
    methods[i] = new_method->as_MethodInstance();
  }
  return node;
}

Node* ReplacingVisitor::visit_Field(Field* node) { UNREACHABLE(); return null; }
Node* ReplacingVisitor::visit_Builtin(Builtin* node) { UNREACHABLE(); return null; }
Node* ReplacingVisitor::visit_Local(Local* node) { UNREACHABLE(); return null; }
Node* ReplacingVisitor::visit_Parameter(Parameter* node) { return visit_Local(node); }
Node* ReplacingVisitor::visit_CapturedLocal(CapturedLocal* node) { return visit_Parameter(node); }
Node* ReplacingVisitor::visit_Block(Block* node) { return visit_Local(node); }

Node* ReplacingVisitor::visit_Method(Method* node) {
  if (node->has_body()) {
    auto replacement = this->visit(node->body());
    ASSERT(replacement->is_Expression());
    node->replace_body(replacement->as_Expression());
  }

  return node;
}
Node* ReplacingVisitor::visit_MethodInstance(MethodInstance* node) { return visit_Method(node); }
Node* ReplacingVisitor::visit_MonitorMethod(MonitorMethod* node) { return visit_Method(node); }
Node* ReplacingVisitor::visit_MethodStatic(MethodStatic* node) { return visit_Method(node); }
Node* ReplacingVisitor::visit_Constructor(Constructor* node) { return visit_Method(node); }
Node* ReplacingVisitor::visit_Global(Global* node) { return visit_Method(node); }
Node* ReplacingVisitor::visit_AdapterStub(AdapterStub* node) { return visit_Method(node); }
Node* ReplacingVisitor::visit_IsInterfaceStub(IsInterfaceStub* node) { return visit_Method(node); }
Node* ReplacingVisitor::visit_FieldStub(FieldStub* node) { return visit_Method(node); }

Expression* ReplacingVisitor::_replace_expression(Expression* expression) {
  auto replacement = visit(expression);
  ASSERT(replacement->is_Expression());
  return replacement->as_Expression();
}

Node* ReplacingVisitor::visit_Expression(Expression* node) { return node; }

Node* ReplacingVisitor::visit_Error(Error* node) {
  auto nested = node->nested();
  for (int i = 0; i < nested.length(); i++) {
    nested[i] = _replace_expression(nested[i]);
  }
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_Nop(Nop* node) { return visit_Expression(node); }

Node* ReplacingVisitor::visit_FieldStore(FieldStore* node) {
  node->replace_value(_replace_expression(node->value()));
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_FieldLoad(FieldLoad* node) {
  node->replace_receiver(_replace_expression(node->receiver()));
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_Sequence(Sequence* node) {
  auto expressions = node->expressions();
  for (int i = 0; i < expressions.length(); i++) {
    expressions[i] = _replace_expression(expressions[i]);
  }
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_TryFinally(TryFinally* node) {
  auto new_body = visit(node->body());
  ASSERT(new_body->is_Code());
  node->replace_body(new_body->as_Code());

  node->replace_handler(_replace_expression(node->handler()));

  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_If(If* node) {
  node->replace_condition(_replace_expression(node->condition()));
  node->replace_yes(_replace_expression(node->yes()));
  node->replace_no(_replace_expression(node->no()));

  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_Not(Not* node) {
  node->replace_value(_replace_expression(node->value()));

  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_While(While* node) {
  node->replace_condition(_replace_expression(node->condition()));
  node->replace_body(_replace_expression(node->body()));
  node->replace_update(_replace_expression(node->update()));

  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_LoopBranch(LoopBranch* node) {
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_Code(Code* node) {
  node->replace_body(_replace_expression(node->body()));

  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_Reference(Reference* node) { return visit_Expression(node); }

Node* ReplacingVisitor::visit_ReferenceClass(ReferenceClass* node) { return visit_Reference(node); }
Node* ReplacingVisitor::visit_ReferenceMethod(ReferenceMethod* node) { return visit_Reference(node); }
Node* ReplacingVisitor::visit_ReferenceLocal(ReferenceLocal* node) { return visit_Reference(node); }
Node* ReplacingVisitor::visit_ReferenceBlock(ReferenceBlock* node) { return visit_Reference(node); }
Node* ReplacingVisitor::visit_ReferenceGlobal(ReferenceGlobal* node) { return visit_Reference(node); }

Node* ReplacingVisitor::visit_Dot(Dot* node) {
  node->replace_receiver(_replace_expression(node->receiver()));

  return node;
}

Node* ReplacingVisitor::visit_LspSelectionDot(LspSelectionDot* node) { return visit_Dot(node); }

/// The "super" visit-calls only happen once the nodes have replaced their own
/// children. Therefore we don't want to replace target and arguments in `visit_Call`.
static void replace_arguments(ReplacingVisitor* visitor, Call* node) {
  auto arguments = node->arguments();
  for (int i = 0; i < arguments.length(); i++) {
    auto replacement = visitor->visit(arguments[i]);
    ASSERT(replacement->is_Expression());
    arguments[i] = replacement->as_Expression();
  }
}

Node* ReplacingVisitor::visit_Super(Super* node) {
  if (node->expression() != null) {
    node->replace_expression(_replace_expression(node->expression()));
  }
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_Call(Call* node) { return visit_Expression(node); }

Node* ReplacingVisitor::visit_CallStatic(CallStatic* node) {
  auto replacement = visit(node->target());
  ASSERT(replacement->is_ReferenceMethod());
  node->replace_method(replacement->as_ReferenceMethod());
  replace_arguments(this, node);

  return visit_Call(node);
}

Node* ReplacingVisitor::visit_Lambda(Lambda* node) {
  return visit_CallStatic(node);
}

Node* ReplacingVisitor::visit_CallConstructor(CallConstructor* node) {
  auto replacement = visit(node->target());
  ASSERT(replacement->is_ReferenceMethod());
  node->replace_method(replacement->as_ReferenceMethod());
  replace_arguments(this, node);

  return visit_Call(node);
}

Node* ReplacingVisitor::visit_CallVirtual(CallVirtual* node) {
  auto replacement = visit(node->target());
  ASSERT(replacement->is_Dot());
  node->replace_target(replacement->as_Dot());
  replace_arguments(this, node);

  return visit_Call(node);
}

Node* ReplacingVisitor::visit_CallBlock(CallBlock* node) {
  auto replacement = visit(node->target());
  ASSERT(replacement->is_ReferenceLocal() &&
         replacement->as_ReferenceLocal()->is_block());
  node->replace_target(replacement->as_ReferenceLocal());
  replace_arguments(this, node);

  return visit_Call(node);
}

Node* ReplacingVisitor::visit_CallBuiltin(CallBuiltin* node) {
  replace_arguments(this, node);
  return visit_Call(node);
}

Node* ReplacingVisitor::visit_Typecheck(Typecheck* node) {
  node->replace_expression(_replace_expression(node->expression()));
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_Return(Return* node) {
  node->replace_value(_replace_expression(node->value()));

  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_LogicalBinary(LogicalBinary* node) {
  node->replace_left(_replace_expression(node->left()));
  node->replace_right(_replace_expression(node->right()));

  return visit_Expression(node);
}

/// The "super" visit-calls only happen once the nodes have replaced their own
/// children. Therefore we don't want to replace the right-side in `visit_Assignment`.
static Node* replace_assignment(ReplacingVisitor* visitor, Assignment* node) {
  auto replacement = visitor->visit(node->right());
  ASSERT(replacement->is_Expression());
  node->replace_right(replacement->as_Expression());
  return visitor->visit_Assignment(node);
}

Node* ReplacingVisitor::visit_Assignment(Assignment* node) {
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_AssignmentLocal(AssignmentLocal* node) {
  return replace_assignment(this, node);
}

Node* ReplacingVisitor::visit_AssignmentGlobal(AssignmentGlobal* node) {
  return replace_assignment(this, node);
}

Node* ReplacingVisitor::visit_AssignmentDefine(AssignmentDefine* node) {
  return replace_assignment(this, node);
}

Node* ReplacingVisitor::visit_Literal(Literal* node) {
  return visit_Expression(node);
}

Node* ReplacingVisitor::visit_LiteralNull(LiteralNull* node) { return visit_Literal(node); }
Node* ReplacingVisitor::visit_LiteralUndefined(LiteralUndefined* node) { return visit_Literal(node); }
Node* ReplacingVisitor::visit_LiteralInteger(LiteralInteger* node) { return visit_Literal(node); }
Node* ReplacingVisitor::visit_LiteralFloat(LiteralFloat* node) { return visit_Literal(node); }
Node* ReplacingVisitor::visit_LiteralString(LiteralString* node) { return visit_Literal(node); }
Node* ReplacingVisitor::visit_LiteralByteArray(LiteralByteArray* node) { return visit_Literal(node); }
Node* ReplacingVisitor::visit_LiteralBoolean(LiteralBoolean* node) { return visit_Literal(node); }

Node* ReplacingVisitor::visit_PrimitiveInvocation(PrimitiveInvocation* node) {
  return visit_Expression(node);
}

class Printer : public Visitor {
 public:
  explicit Printer(bool use_resolution_shape)
      : _indentation(0), _use_resolution_shape(use_resolution_shape) { }

  template<typename T>
  void _visit_multiple(List<T> nodes, char separation = '\n') {
    bool should_indent = separation == '\n';
    if (should_indent) _indentation++;
    for (int i = 0; i < nodes.length(); i++) {
      if (should_indent) {
        indent();
      } else if (i != 0) {
        printf("%c", separation);
      }
      nodes[i]->accept(this);
    }
    if (should_indent) _indentation--;
  }

  void visit_Program(Program* node) {
    printf("-------- program --------\n");
    List<Method*> methods = node->methods();
    for (int i = 0; i < methods.length(); i++) {
      if (i != 0) printf("\n");
      methods[i]->accept(this);
    }

    List<Global*> globals = node->globals();
    for (auto global : globals) {
      printf("Global %s:\n", global->name().c_str());
      global->accept(this);
    }

    for (auto klass : node->classes()) {
      klass->accept(this);
    }
    printf("-------------------------\n");
  }

  void visit_Class(Class* node) {
    printf("\nClass %s", node->name().c_str());
    if (node->super() != null) {
      printf(" %s\n", node->super()->name().c_str());
    }
    _indentation++;
    for (auto field : node->fields()) visit(field);
    for (auto method : node->methods()) visit(method);
    _indentation--;
  }
  void visit_Field(Field* node) {
    indent();
    printf("Field: %s\n", node->name().c_str());
  }

  void visit_Expression(Expression* node) { UNREACHABLE(); }

  void visit_Error(Error* node) {
    indent();
    printf("(ERROR:");
    _indentation++;
    for (auto nested : node->nested()) {
      printf("\n");
      indent();
      visit(nested);
    }
    _indentation--;
    printf("\n");
    indent();
    printf(")");
  }
  void visit_Reference(Reference* node) { UNREACHABLE(); }
  void visit_Literal(Literal* node) { UNREACHABLE(); }

  void visit_Method(Method* node) {
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
    if (_use_resolution_shape) {
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

    _indentation++;
    if (node->has_body()) {
      visit(node->body());
    }
    _indentation--;

    indent();
    printf(")\n");
  }

  void visit_MethodInstance(MethodInstance* node) { visit_Method(node); }
  void visit_MonitorMethod(MonitorMethod* node) { visit_Method(node); }
  void visit_MethodStatic(MethodStatic* node) { visit_Method(node); }
  void visit_Constructor(Constructor* node) { visit_Method(node); }
  void visit_Global(Global* node) { visit_Method(node); }
  void visit_AdapterStub(AdapterStub* node) { visit_Method(node); }
  void visit_FieldStub(FieldStub* node) { visit_Method(node); }

  void visit_IsInterfaceStub(IsInterfaceStub* node) {
    indent();
    printf("Is-interface stub: %s\n", node->name().c_str());
  }

  void visit_Code(Code* node) {
    indent();
    printf("(code:");
    auto parameters = node->parameters();
    if (!parameters.is_empty()) {
      printf("|");
      _visit_multiple(parameters, ' ');
      printf("|");
    }
    printf("\n");
    _indentation++;

    visit(node->body());

    _indentation--;
    indent();
    printf(")\n");
  }

  void visit_Nop(Nop* node) {
    printf("NOP");
  }

  void visit_TryFinally(TryFinally* node) {
    indent();
    printf("(try:\n");
    _indentation++;
    visit(node->body());
    _indentation--;
    indent();
    printf("finally:");
    if (!node->handler_parameters().is_empty()) {
      printf("|");
      _visit_multiple(node->handler_parameters(), ' ');
      printf("|");
    }
    printf("\n");
    _indentation++;
    visit(node->handler());
    _indentation--;
    indent();
    printf(")\n");
  }

  void visit_If(If* node) {
    indent();
    printf("(if ");
    visit(node->condition());
    printf(":\n");

    _indentation++;
    visit(node->yes());
    _indentation--;

    indent();
    printf("else:");

    _indentation++;
    visit(node->no());
    _indentation--;

    indent();
    printf(")\n");
  }

  void visit_Not(Not* node) {
    printf("!");
    visit(node->value());
  }

  void visit_While(While* node) {
    indent();
    printf("(while ");
    visit(node->condition());
    printf(":\n");

    _indentation++;
    visit(node->body());
    _indentation--;

    printf("update:\n");

    _indentation++;
    visit(node->update());
    _indentation--;

    indent();
    printf(")\n");
  }

  void visit_LoopBranch(LoopBranch* node) {
    const char* kind = node->is_break() ? "break" : "continue";
    indent();
    if (node->block_depth() == 0) {
      printf("%s\n", kind);
    } else {
      printf("%s(%d)\n", kind, node->block_depth());
    }
  }

  void visit_LogicalBinary(LogicalBinary* node) {
    visit(node->left());
    printf(" %s ", node->op() == LogicalBinary::AND ? "&&" : "||");
    visit(node->right());
  }

  void visit_Sequence(Sequence* node) {
    indent();
    printf("(sequence:\n");

    _visit_multiple(node->expressions());
    printf("\n");

    indent();
    printf(")\n");
  }

  void visit_FieldLoad(FieldLoad* node) {
    if (node->is_box_load()) {
      printf("(BoxRead (");
    } else {
      printf("(FieldRead (");
    }
    node->receiver()->accept(this);
    printf(").%s)", node->field()->name().c_str());
  }

  void visit_FieldStore(FieldStore* node) {
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

  void visit_Super(Super* node) {
    if (node->expression() == null) {
      printf("super");
    } else {
      printf("(super ");
      visit(node->expression());
      printf(")");
    }
  }

  void visit_Call(Call* node) {
    printf("(Call (%d,%d,%d",
           node->shape().arity(),
           node->shape().total_block_count(),
           node->shape().named_block_count());
    for (auto name : node->shape().names()) {
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

  void visit_CallStatic(CallStatic* node) { visit_Call(node); }
  void visit_CallVirtual(CallVirtual* node) { visit_Call(node); }
  void visit_CallConstructor(CallConstructor* node) { visit_Call(node); }
  void visit_CallBuiltin(CallBuiltin* node) { visit_Builtin(node->target()); }

  void visit_Lambda(Lambda* node) {
    printf("(Lamba:\n");
    _indentation++;
    visit(node->arguments()[1]);
    _indentation--;
    indent();
    printf("-- Body:\n");
    _indentation++;
    visit(node->code());
    _indentation--;

    indent();
    printf(")");
  }

  void visit_CallBlock(CallBlock* node) {
    printf("(Call Block ");
    node->target()->accept(this);
    printf(".call :\n");

    _visit_multiple(node->arguments());
    printf("\n");

    indent();
    printf(")");
  }

  void visit_Builtin(Builtin* node) {
    const char* name = "unknown";
    switch (node->kind()) {
      case Builtin::THROW: name = "throw"; break;
      case Builtin::HALT: name = "halt"; break;
      case Builtin::EXIT: name = "exit"; break;
      case Builtin::INVOKE_LAMBDA: name = "invoke_lambda"; break;
      case Builtin::YIELD: name = "yield"; break;
      case Builtin::DEEP_SLEEP: name = "deep_sleep"; break;
      case Builtin::STORE_GLOBAL: name = "store_global"; break;
      case Builtin::INVOKE_INITIALIZER: name = "invoke_initializer"; break;
      case Builtin::GLOBAL_ID: name = "global_id"; break;
    }
    printf("Builtin-%s", name);
  }

  void visit_ReferenceClass(ReferenceClass* node) {
    auto target = node->target();
    printf("%s", target->name().c_str());
  }

  void visit_ReferenceMethod(ReferenceMethod* node) {
    auto target = node->target();
    int arity;
    int block_count;
    if (_use_resolution_shape) {
      arity = target->resolution_shape().max_arity();
      block_count = target->resolution_shape().total_block_count();
    } else {
      arity = target->plain_shape().arity();
      block_count = target->plain_shape().total_block_count();
    }
    printf("%s (%d, %d)", target->name().c_str(), arity, block_count);
  }

  void visit_ReferenceLocal(ReferenceLocal* node) {
    if (node->block_depth() == 0) {
      printf("%s", node->target()->name().c_str());
    } else {
      printf("%s(%d)", node->target()->name().c_str(), node->block_depth());
    }
  }

  void visit_ReferenceBlock(ReferenceBlock* node) {
    printf("<BlockRef>");
  }

  void visit_ReferenceGlobal(ReferenceGlobal* node) {
    printf("%s%s", node->target()->name().c_str(), node->is_lazy() ? "" : "(eager)");
  }

  void visit_Local(Local* node) {
    printf("%s", node->name().c_str());
  }

  void visit_Parameter(Parameter* node) { visit_Local(node); }
  void visit_CapturedLocal(CapturedLocal* node) { visit_Parameter(node); }

  void visit_Block(Block* node) { visit_Local(node); }

  void visit_Dot(Dot* node) {
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

  void visit_LspSelectionDot(LspSelectionDot* node) {
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

  void visit_PrimitiveInvocation(PrimitiveInvocation* node) {
    printf("{{%s:%s}}", node->module().c_str(), node->primitive().c_str());
  }

  void visit_Typecheck(Typecheck* node) {
    printf("(");
    visit(node->expression());
    printf(" %s %s%s",
           node->is_as_check() ? "as" : "is",
           node->type_name().c_str(),
           node->type().is_nullable() ? "?" : "");
    printf(")");
  }

  void visit_Return(Return* node) {
    printf("(return ");
    node->value()->accept(this);
    printf(")");
  }

  void visit_Assignment(Assignment* node) {
    UNREACHABLE();
  }

  void visit_AssignmentLocal(AssignmentLocal* node) {
    if (node->block_depth() == 0) {
      printf("%s = ", node->local()->name().c_str());
    } else {
      printf("%s(%d) = ", node->local()->name().c_str(), node->block_depth());
    }
    node->right()->accept(this);
  }

  void visit_AssignmentGlobal(AssignmentGlobal* node) {
    printf("%s = ", node->global()->name().c_str());
    node->right()->accept(this);
  }

  void visit_AssignmentDefine(AssignmentDefine* node) {
    node->left()->accept(this);
    printf(" := ");
    node->right()->accept(this);
  }

  void visit_LiteralNull(LiteralNull* node) {
    printf("null");
  }

  void visit_LiteralUndefined(LiteralUndefined* node) {
    printf("<undefined>");
  }

  void visit_LiteralInteger(LiteralInteger* node) {
    printf("%lld", node->value());
  }

  void visit_LiteralFloat(LiteralFloat* node) {
    printf("%g", node->value());
  }

  void visit_LiteralString(LiteralString* node) {
    printf("%s", node->value());
  }

  void visit_LiteralByteArray(LiteralByteArray* node) {
    printf("[");
    int length = node->data().length();
    for (int i = 0; i < length; i++) {
      printf("0x%x%s", node->data()[i], i == length - 1 ? "" : ", ");
    }
    printf("]");
  }

  void visit_LiteralBoolean(LiteralBoolean* node) {
    printf("%s", node->value() ? "true" : "false");
  }

 private:
  int _indentation;
  bool _use_resolution_shape;

  void indent() {
    for (int i = 0; i < _indentation; i++) {
      printf("  ");
    }
  }
};

void Node::print(bool use_resolution_shape) {
  Printer printer(use_resolution_shape);
  accept(&printer);
}

} // namespace toit::compiler::ir
} // namespace toit::compiler
} // namespace toit
