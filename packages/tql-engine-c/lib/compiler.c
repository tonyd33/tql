#include "compiler.h"
#include "program.h"
#include <stdio.h>

DA_DEFINE(AsmOp, AsmOps)

static inline void compile_tql_selector(Compiler *compiler,
                                        TQLSelector *selector, AsmOps *out);
static inline void compile_tql_statement(Compiler *compiler,
                                         TQLStatement *statement, AsmOps *out);
static inline void compile_tql_expression(Compiler *compiler,
                                          TQLExpression *expr, AsmOps *out);
static inline void compile_tql_condition(Compiler *compiler,
                                         TQLCondition *condition, AsmOps *out);

static inline SymbolId compiler_request_symbol(Compiler *compiler) {
  return compiler->next_symbol_id++;
}

static inline SymbolId compiler_symbol_for_variable(Compiler *compiler,
                                                    const char *string) {
  for (int i = 0; i < compiler->symbol_table.len; i++) {
    SymbolEntry entry = compiler->symbol_table.data[i];
    if (entry.type == SYMBOL_VARIABLE &&
        strcmp(string, entry.data.string) == 0) {
      return entry.id;
    }
  }

  SymbolId new_symbol = compiler_request_symbol(compiler);
  SymbolEntry new_entry = {
      .id = new_symbol, .type = SYMBOL_VARIABLE, .data = {.string = string}};
  SymbolTable_append(&compiler->symbol_table, new_entry);
  return new_symbol;
}

void compiler_init(Compiler *compiler, const TSLanguage *language) {
  assembler_init(&compiler->asmb, language);
  SymbolTable_init(&compiler->symbol_table);
}

void compiler_free(Compiler *compiler) {
  SymbolTable_free(&compiler->symbol_table);
  assembler_free(&compiler->asmb);
}

static inline void compile_tql_expression(Compiler *compiler,
                                          TQLExpression *expr, AsmOps *out) {
  switch (expr->type) {
  case TQLEXPRESSION_SELECTOR:
    compile_tql_selector(compiler, expr->data.selector, out);
    break;
  }
}

static inline void compile_tql_condition(Compiler *compiler,
                                         TQLCondition *condition, AsmOps *out) {
  switch (condition->type) {
  case TQLCONDITION_TEXTEQ: {
    AsmOps_append(out, asmop_pushnode(&compiler->asmb));
    compile_tql_expression(compiler, condition->data.empty_condition.expression,
                           out);
    AsmOps_append(
        out,
        asmop_if(
            &compiler->asmb,
            (AsmPredicate){
                .predicate_type = PREDICATE_TEXTEQ,
                .data = {.texteq = {.node_expression = node_expression_self(),
                                    .text = condition->data.text_eq_condition
                                                .string->string}}}));
    AsmOps_append(out, asmop_popnode(&compiler->asmb));

  } break;
  case TQLCONDITION_EMPTY: {
    SymbolId fid = compiler_request_symbol(compiler);

    AsmOps inner;
    AsmOps_init(&inner);
    compile_tql_expression(compiler, condition->data.empty_condition.expression,
                           &inner);
    AsmOps_append(&inner, asmop_yield(&compiler->asmb));
    AsmOps_append(&inner, asmop_halt(&compiler->asmb));
    assembler_register_function(&compiler->asmb, fid, inner.data, inner.len);
    AsmOps_free(&inner);

    AsmOps_append(out, asmop_probe(&compiler->asmb, (AsmProbe){
                                                        .mode = PROBE_NOTEXISTS,
                                                        .jump = {.symbol = fid},
                                                    }));
  } break;
  case TQLCONDITION_AND: {
    compile_tql_condition(compiler,
                          condition->data.binary_condition.condition_1, out);
    compile_tql_condition(compiler,
                          condition->data.binary_condition.condition_2, out);
  } break;
  case TQLCONDITION_OR:
    break;
  }
}

static inline void compile_tql_statement(Compiler *compiler,
                                         TQLStatement *statement, AsmOps *out) {
  switch (statement->type) {
  case TQLSTATEMENT_SELECTOR: {
    AsmOps_append(out, asmop_pushnode(&compiler->asmb));
    compile_tql_selector(compiler, statement->data.selector, out);
    AsmOps_append(out, asmop_popnode(&compiler->asmb));
  } break;
  case TQLSTATEMENT_ASSIGNMENT: {
    SymbolId aid = compiler_symbol_for_variable(
        compiler, statement->data.assignment->variable_identifier->string);
    AsmOps_append(out, asmop_pushnode(&compiler->asmb));
    compile_tql_expression(compiler, statement->data.assignment->expression,
                           out);
    AsmOps_append(out, asmop_bind(&compiler->asmb, aid));
    AsmOps_append(out, asmop_popnode(&compiler->asmb));
  } break;
  case TQLSTATEMENT_CONDITION: {
    compile_tql_condition(compiler, statement->data.condition, out);
  } break;
  }
}

static inline void compile_tql_selector(Compiler *compiler,
                                        TQLSelector *selector, AsmOps *out) {
  switch (selector->type) {
  case TQLSELECTOR_SELF:
    break;
  case TQLSELECTOR_UNIVERSAL:
    assert(false && "Not implemented");
    break;
  case TQLSELECTOR_NODETYPE:
    AsmOps_append(
        out,
        asmop_if(
            &compiler->asmb,
            (AsmPredicate){
                .predicate_type = PREDICATE_TYPEEQ,
                .negate = false,
                .data = {
                    .typeeq = {.node_expression = node_expression_self(),
                               .type =
                                   selector->data.node_type_selector->string},
                }}));
    break;
  case TQLSELECTOR_FIELDNAME:
    if (selector->data.field_name_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.field_name_selector.parent,
                           out);
    }
    AsmOps_append(
        out,
        asmop_branch(
            &compiler->asmb,
            (AsmAxis){
                .axis_type = AXIS_FIELD,
                .data = {.field =
                             selector->data.field_name_selector.field->string},
            }));
    break;
  case TQLSELECTOR_CHILD:
    if (selector->data.child_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.child_selector.parent, out);
    }
    AsmOps_append(
        out, asmop_branch(&compiler->asmb, (AsmAxis){.axis_type = AXIS_CHILD}));
    compile_tql_selector(compiler, selector->data.child_selector.child, out);
    break;
  case TQLSELECTOR_DESCENDANT:
    if (selector->data.descendant_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.descendant_selector.parent,
                           out);
    }
    AsmOps_append(out, asmop_branch(&compiler->asmb,
                                    (AsmAxis){.axis_type = AXIS_DESCENDANT}));
    compile_tql_selector(compiler, selector->data.descendant_selector.child,
                         out);
    break;
  case TQLSELECTOR_BLOCK: {
    if (selector->data.block_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.block_selector.parent, out);
    }
    for (int i = 0; i < selector->data.block_selector.statement_count; i++) {
      compile_tql_statement(compiler,
                            selector->data.block_selector.statements[i], out);
    }
  } break;
  case TQLSELECTOR_VARID: {
    SymbolId sid = compiler_symbol_for_variable(
        compiler, selector->data.variable_identifier_selector->string);
    AsmOps_append(

        out,
        asmop_branch(&compiler->asmb, (AsmAxis){.axis_type = AXIS_VAR,
                                                // FIXME
                                                .data = {.variable = sid}}));
    break;
  }
  }
}

static inline void op_name(const Compiler *compiler, Op op) {
  switch (op.opcode) {
  case OP_NOOP:
    printf("noop");
    break;
  case OP_HALT:
    printf("halt");
    break;
  case OP_BRANCH:
    switch (op.data.axis.axis_type) {
    case AXIS_CHILD:
      printf("branch (child)");
      break;
    case AXIS_DESCENDANT:
      printf("branch (descendant)");
      break;
    case AXIS_FIELD:
      printf("branch (field \"%s\")",
             ts_language_field_name_for_id(compiler->asmb.target,
                                           op.data.axis.data.field));
      break;
    case AXIS_VAR:
      printf("branch (var %llu)", op.data.axis.data.variable);
      break;
    }
    break;
  case OP_BIND:
    printf("bind %llu", op.data.var_id);
    break;
  case OP_IF:
    switch (op.data.predicate.predicate_type) {
    case PREDICATE_TEXTEQ:
      printf("if (texteq \"%s\")", op.data.predicate.data.texteq.text);
      break;
    case PREDICATE_TYPEEQ:
      printf("if (typeeq \"%s\")",
             ts_language_symbol_name(compiler->asmb.target,
                                     op.data.predicate.data.typeeq.symbol));
      break;
    }
    break;
  case OP_YIELD:
    printf("yield");
    break;
  case OP_JMP:
    printf("jmp %d", op.data.jump.pc);
    break;
  case OP_PROBE: {
    switch (op.data.probe.mode) {
    case PROBE_EXISTS:
      printf("probe (exists %d)", op.data.probe.jump.pc);
      break;
    case PROBE_NOTEXISTS:
      printf("probe (notexists %d)", op.data.probe.jump.pc);
      break;
    }
  } break;
  case OP_PUSH:
    switch (op.data.push_target) {
    case PUSH_NODE:
      printf("push (node)");
      break;
    case PUSH_PC:
      printf("push (pc)");
      break;
    }
    break;
  case OP_POP:
    switch (op.data.push_target) {
    case PUSH_NODE:
      printf("pop (node)");
      break;
    case PUSH_PC:
      printf("pop (pc)");
      break;
    }
    break;
  }
}

Op *compile_tql_tree(Compiler *compiler, const TQLTree *tree,
                     uint32_t *op_count) {
  AsmOps ops;
  AsmOps_init(&ops);
  SymbolId main_id = compiler_request_symbol(compiler);

  for (int i = 0; i < tree->selector_count; i++) {
    compile_tql_selector(compiler, tree->selectors[i], &ops);
  }
  AsmOps_append(&ops, asmop_yield(&compiler->asmb));
  AsmOps_append(&ops, asmop_halt(&compiler->asmb));
  assembler_register_function(&compiler->asmb, main_id, ops.data, ops.len);

  Op *out = assembler_serialize(&compiler->asmb, main_id, op_count);
  for (int i = 0; i < *op_count; i++) {
    printf("pc %d op ", i);
    op_name(compiler, out[i]);
    printf("\n");
  }

  AsmOps_free(&ops);
  return out;
}

void compiler_compile(Compiler *compiler, TQLAst *ast) {}
