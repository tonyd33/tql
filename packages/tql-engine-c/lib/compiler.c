#include "compiler.h"
#include "ast.h"
#include "languages.h"
#include <stdio.h>

DA_DEFINE(Op, Ops, ops)

// asm ops {{{
typedef uint64_t Symbol;

struct IrJump;
struct IrProbe;
struct IrOp;

typedef struct IrJump IrJump;
typedef struct IrProbe IrProbe;
typedef struct IrOp IrInstr;

typedef struct IrAxis {
  AxisType axis_type;
  union {
    Symbol field;
    Symbol variable;
  } data;
} IrAxis;

typedef struct {
  PredicateType predicate_type;
  bool negate;
  union {
    struct {
      NodeExpression node_expression;
      const char *type;
    } typeeq;
    struct {
      NodeExpression node_expression;
      const char *text;
    } texteq;
  } data;
} IrPredicate;

struct IrProbe {
  ProbeMode mode;
  Symbol jump;
};

struct IrOp {
  Opcode opcode;
  union {
    IrAxis axis;
    IrPredicate predicate;
    Symbol variable;
    IrProbe probe;
    Symbol jump;
    PushTarget push_target;
  } data;
};
DA_DEFINE(IrInstr, IrInstrs, ir_instrs)

static inline IrProbe ir_probe_exists(Symbol symbol) {
  return (IrProbe){.mode = PROBE_EXISTS, .jump = symbol};
}
static inline IrProbe ir_probe_not_exists(Symbol symbol) {
  return (IrProbe){.mode = PROBE_NOTEXISTS, .jump = symbol};
}
static inline IrPredicate ir_predicate_typeeq(NodeExpression ne,
                                                    const char *type) {
  return (IrPredicate){
      .predicate_type = PREDICATE_TYPEEQ,
      .negate = false,
      .data = {.typeeq = {.node_expression = ne, .type = type}}};
}
static inline IrPredicate ir_predicate_texteq(NodeExpression ne,
                                                    const char *text) {
  return (IrPredicate){
      .predicate_type = PREDICATE_TEXTEQ,
      .negate = false,
      .data = {.texteq = {.node_expression = ne, .text = text}}};
}
static inline IrAxis ir_axis_field(Symbol field) {
  return (IrAxis){.axis_type = AXIS_FIELD, .data = {.field = field}};
}
static inline IrAxis ir_axis_child(void) {
  return (IrAxis){.axis_type = AXIS_CHILD};
}
static inline IrAxis ir_axis_descendant(void) {
  return (IrAxis){.axis_type = AXIS_DESCENDANT};
}
static inline IrAxis ir_axis_var(Symbol variable) {
  return (IrAxis){.axis_type = AXIS_VAR, .data = {.variable = variable}};
}
static inline IrInstr ir_noop(void) {
  return (IrInstr){.opcode = OP_NOOP};
}
static inline IrInstr ir_branch(IrAxis axis) {
  return (IrInstr){.opcode = OP_BRANCH, .data = {.axis = axis}};
}
static inline IrInstr ir_bind(Symbol symbol) {
  return (IrInstr){.opcode = OP_BIND, .data = {.variable = symbol}};
}
static inline IrInstr ir_if(IrPredicate predicate) {
  return (IrInstr){.opcode = OP_IF, .data = {.predicate = predicate}};
}
static inline IrInstr ir_probe(IrProbe probe) {
  return (IrInstr){.opcode = OP_PROBE, .data = {.probe = probe}};
}
static inline IrInstr ir_halt(void) {
  return (IrInstr){.opcode = OP_HALT};
}
static inline IrInstr ir_yield(void) {
  return (IrInstr){.opcode = OP_YIELD};
}
static inline IrInstr ir_pushnode(void) {
  return (IrInstr){.opcode = OP_PUSH, .data = {.push_target = PUSH_NODE}};
}
static inline IrInstr ir_popnode(void) {
  return (IrInstr){.opcode = OP_POP, .data = {.push_target = PUSH_NODE}};
}
static inline IrInstr ir_jump(Symbol id) {
  return (IrInstr){.opcode = OP_JMP, .data = {.jump = id}};
}
static inline IrInstr ir_call(Symbol id) {
  return (IrInstr){.opcode = OP_CALL, .data = {.jump = id}};
}
static inline IrInstr ir_ret(void) { return (IrInstr){.opcode = OP_RET}; }
// }}}

// compiler {{{

struct Section {
  Symbol symbol;
  IrInstrs ops;
  uint32_t placement;
};
DA_DEFINE(Section, SectionTable, section_table)

struct TQLCompiler {
  TQLAst *ast;
  Symbol next_symbol_id;
  SymbolTable *symbol_table;
  SectionTable section_table;
  const TSLanguage *target;
};
// }}}

static inline void compiler_section_insert(TQLCompiler *compiler, Symbol symbol,
                                           IrInstrs *ops) {
  Section section;
  section.symbol = symbol;
  section.placement = 0;
  ir_instrs_clone(&section.ops, ops);
  section_table_append(&compiler->section_table, section);
}

static inline void compile_tql_selector(TQLCompiler *compiler,
                                        TQLSelector *selector, IrInstrs *out);
static inline void compile_tql_statement(TQLCompiler *compiler,
                                         TQLStatement *statement,
                                         IrInstrs *out);
static inline void compile_tql_expression(TQLCompiler *compiler,
                                          TQLExpression *expr, IrInstrs *out);
size_t compiler_lookup_section_placement(const TQLCompiler *compiler,
                                         Symbol symbol);

static inline Symbol compiler_request_symbol(TQLCompiler *compiler) {
  return compiler->next_symbol_id++;
}

static inline Symbol compiler_symbol_for_symbol_type(TQLCompiler *compiler,
                                                     SymbolType symbol_type,
                                                     StringSlice slice) {
  for (size_t i = 0; i < compiler->symbol_table->len; i++) {
    SymbolEntry entry = compiler->symbol_table->data[i];
    if (entry.type == symbol_type && string_slice_eq(entry.slice, slice)) {
      return entry.id;
    }
  }

  Symbol new_symbol = compiler_request_symbol(compiler);
  SymbolEntry new_entry = {
      .id = new_symbol, .type = symbol_type, .slice = slice, .placement = 0};
  symbol_table_append(compiler->symbol_table, new_entry);
  return new_symbol;
}

static inline Symbol compiler_symbol_for_field(TQLCompiler *compiler,
                                               StringSlice slice) {
  return compiler_symbol_for_symbol_type(compiler, SYMBOL_FIELD, slice);
}

static inline Symbol compiler_symbol_for_variable(TQLCompiler *compiler,
                                                  StringSlice slice) {
  return compiler_symbol_for_symbol_type(compiler, SYMBOL_VARIABLE, slice);
}

static inline Symbol compiler_symbol_for_function(TQLCompiler *compiler,
                                                  StringSlice slice) {
  return compiler_symbol_for_symbol_type(compiler, SYMBOL_FUNCTION, slice);
}

static inline const TSLanguage *get_ast_target(TQLAst *ast) {
  for (int i = 0; i < ast->tree->directive_count; i++) {
    TQLDirective directive = *ast->tree->directives[i];
    if (directive.type == TQLDIRECTIVE_TARGET) {
      return ts_language_for_name(directive.data.target->buf,
                                  directive.data.target->length);
      assert(false && "Unknown language");
    }
  }

  return NULL;
}

void compiler_init(TQLCompiler *compiler, TQLAst *ast, SymbolTable *symtab) {
  compiler->ast = ast;
  compiler->target = get_ast_target(ast);
  assert(compiler->target != NULL);

  compiler->next_symbol_id = 0;
  compiler->symbol_table = symtab;
  section_table_init(&compiler->section_table);
}

TQLCompiler *tql_compiler_new(TQLAst *ast, SymbolTable *symtab) {
  TQLCompiler *compiler = malloc(sizeof(TQLCompiler));
  compiler_init(compiler, ast, symtab);
  return compiler;
}

void compiler_deinit(TQLCompiler *compiler) {
  for (size_t i = 0; i < compiler->section_table.len; i++) {
    ir_instrs_deinit(&compiler->section_table.data[i].ops);
  }
  section_table_deinit(&compiler->section_table);
  compiler->symbol_table = NULL;
  compiler->next_symbol_id = 0;
  compiler->target = NULL;
  compiler->ast = NULL;
}

void tql_compiler_free(TQLCompiler *compiler) {
  compiler_deinit(compiler);
  free(compiler);
}

static inline void compile_tql_expression(TQLCompiler *compiler,
                                          TQLExpression *expr, IrInstrs *out) {
  switch (expr->type) {
  case TQLEXPRESSION_SELECTOR:
    compile_tql_selector(compiler, expr->data.selector, out);
    break;
  case TQLEXPRESSION_STRING:
    assert(false && "Not implemented");
    break;
  }
}

static inline void compile_tql_statement(TQLCompiler *compiler,
                                         TQLStatement *statement,
                                         IrInstrs *out) {
  switch (statement->type) {
  case TQLSTATEMENT_SELECTOR: {
    compile_tql_selector(compiler, statement->data.selector, out);
  } break;
  case TQLSTATEMENT_ASSIGNMENT: {
    Symbol symbol = compiler_symbol_for_variable(
        compiler, *statement->data.assignment->variable_identifier);
    compile_tql_expression(compiler, statement->data.assignment->expression,
                           out);
    ir_instrs_append(out, ir_bind(symbol));
  } break;
  }
}

static inline void compile_tql_function_invocation(
    TQLCompiler *compiler, TQLFunctionIdentifier *identifier,
    TQLExpression **exprs, uint16_t expr_count, IrInstrs *out) {
  if (strcmp(identifier->buf, "exists") == 0) {
    assert(expr_count == 1);
    assert(exprs[0]->type == TQLEXPRESSION_SELECTOR);

    Symbol sid = compiler_request_symbol(compiler);
    IrInstrs inner;
    ir_instrs_init(&inner);
    compile_tql_selector(compiler, exprs[0]->data.selector, &inner);
    ir_instrs_append(&inner, ir_yield());
    compiler_section_insert(compiler, sid, &inner);
    ir_instrs_deinit(&inner);

    ir_instrs_append(out, ir_probe(ir_probe_exists(sid)));
  } else if (strcmp(identifier->buf, "text_eq") == 0) {
    assert(expr_count == 2);
    assert(exprs[0]->type == TQLEXPRESSION_SELECTOR);
    assert(exprs[1]->type == TQLEXPRESSION_STRING);

    ir_instrs_append(out, ir_pushnode());
    compile_tql_selector(compiler, exprs[0]->data.selector, out);
    ir_instrs_append(out,
                     ir_if((IrPredicate){
                         .predicate_type = PREDICATE_TEXTEQ,
                         .data = {.texteq = {
                                      .node_expression = node_expression_self(),
                                      .text = exprs[1]->data.string->buf,
                                  }}}));
    ir_instrs_append(out, ir_popnode());
  } else {
    // FIXME: We need to make the argument lazy!
    // FIXME: And we have to NOT pollute the outer binding scope!
    // FIXME: And we have to bind strings correctly
    TQLFunction *function =
        tql_lookup_function(compiler->ast, identifier->buf, identifier->length);
    assert(function != NULL);
    assert(function->parameter_count == expr_count);
    for (int i = 0; i < expr_count; i++) {
      Symbol aid =
          compiler_symbol_for_variable(compiler, *function->parameters[i]);
      ir_instrs_append(out, ir_pushnode());
      compile_tql_expression(compiler, exprs[i], out);
      ir_instrs_append(out, ir_bind(aid));
      ir_instrs_append(out, ir_popnode());
    }

    ir_instrs_append(out, ir_call(compiler_symbol_for_function(
                              compiler, *function->identifier)));
  }
}

static inline void compile_tql_selector(TQLCompiler *compiler,
                                        TQLSelector *selector, IrInstrs *out) {
  switch (selector->type) {
  case TQLSELECTOR_SELF:
    break;
  case TQLSELECTOR_NODETYPE:
    ir_instrs_append(out, ir_if(ir_predicate_typeeq(
                              node_expression_self(),
                              selector->data.node_type_selector->buf)));
    break;
  case TQLSELECTOR_FIELDNAME:
    if (selector->data.field_name_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.field_name_selector.parent,
                           out);
    }
    ir_instrs_append(
        out, ir_branch(ir_axis_field(compiler_symbol_for_field(
                 compiler, *selector->data.field_name_selector.field))));
    break;
  case TQLSELECTOR_CHILD:
    if (selector->data.child_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.child_selector.parent, out);
    }
    ir_instrs_append(out, ir_branch(ir_axis_child()));
    compile_tql_selector(compiler, selector->data.child_selector.child, out);
    break;
  case TQLSELECTOR_DESCENDANT:
    if (selector->data.descendant_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.descendant_selector.parent,
                           out);
    }
    ir_instrs_append(out, ir_branch(ir_axis_descendant()));
    compile_tql_selector(compiler, selector->data.descendant_selector.child,
                         out);
    break;
  case TQLSELECTOR_BLOCK: {
    if (selector->data.block_selector.parent != NULL) {
      compile_tql_selector(compiler, selector->data.block_selector.parent, out);
    }
    for (int i = 0; i < selector->data.block_selector.statement_count; i++) {
      ir_instrs_append(out, ir_pushnode());
      compile_tql_statement(compiler,
                            selector->data.block_selector.statements[i], out);
      ir_instrs_append(out, ir_popnode());
    }
  } break;
  case TQLSELECTOR_VARID: {
    ir_instrs_append(
        out, ir_branch(ir_axis_var(compiler_symbol_for_variable(
                 compiler, *selector->data.variable_identifier_selector))));
    break;
  }
  case TQLSELECTOR_FUNINV:
    compile_tql_function_invocation(
        compiler, selector->data.function_invocation_selector.identifier,
        selector->data.function_invocation_selector.exprs,
        selector->data.function_invocation_selector.expr_count, out);
    break;
  case TQLSELECTOR_NEGATE: {
    Symbol sid = compiler_request_symbol(compiler);
    IrInstrs inner;
    ir_instrs_init(&inner);
    compile_tql_selector(compiler, selector->data.negate_selector, &inner);
    ir_instrs_append(&inner, ir_yield());
    compiler_section_insert(compiler, sid, &inner);
    ir_instrs_deinit(&inner);

    ir_instrs_append(out, ir_probe(ir_probe_not_exists(sid)));
  } break;
  case TQLSELECTOR_AND:
  case TQLSELECTOR_OR:
    assert(false && "Not implemented");
    break;
  }
}

static inline const SymbolEntry *
compiler_lookup_symbol(const TQLCompiler *compiler, Symbol symbol) {
  for (size_t i = 0; i < compiler->symbol_table->len; i++) {
    if (compiler->symbol_table->data[i].id == symbol) {
      return &compiler->symbol_table->data[i];
    }
  }
  return NULL;
}

static inline void print_op(const TQLCompiler *compiler, Op op) {
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
             ts_language_field_name_for_id(compiler->target,
                                           op.data.axis.data.field));
      break;
    case AXIS_VAR: {
      const SymbolEntry *se =
          compiler_lookup_symbol(compiler, op.data.axis.data.variable);
      const char *variable = se->slice.buf;
      if (variable == NULL) {
        variable = "anonymous_variable";
      }
      printf("branch (var %s)", variable);
    } break;
    }
    break;
  case OP_BIND: {
    const SymbolEntry *se = compiler_lookup_symbol(compiler, op.data.var_id);
    const char *variable = se->slice.buf;
    if (variable == NULL) {
      variable = "anonymous_variable";
    }
    printf("bind %s", variable);
  } break;
  case OP_IF:
    switch (op.data.predicate.predicate_type) {
    case PREDICATE_TEXTEQ:
      printf("if (texteq \"%s\")", op.data.predicate.data.texteq.text);
      break;
    case PREDICATE_TYPEEQ:
      printf("if (typeeq \"%s\")",
             ts_language_symbol_name(compiler->target,
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
  case OP_CALL:
    printf("call %d", op.data.jump.pc);
    break;
  case OP_RET:
    printf("ret");
    break;
  }
}

void compile_tql_function(TQLCompiler *compiler, TQLFunction *function) {
  IrInstrs ops;
  ir_instrs_init(&ops);
  for (int i = 0; i < function->statement_count; i++) {
    compile_tql_statement(compiler, function->statements[i], &ops);
  }
  ir_instrs_append(&ops, ir_ret());

  compiler_section_insert(
      compiler, compiler_symbol_for_function(compiler, *function->identifier),
      &ops);
  ir_instrs_deinit(&ops);
}

const Section *compiler_lookup_section(const TQLCompiler *compiler,
                                       Symbol symbol) {
  for (size_t i = 0; i < compiler->section_table.len; i++) {
    if (compiler->section_table.data[i].symbol == symbol) {
      return &compiler->section_table.data[i];
    }
  }
  return NULL;
}

// FIXME: Please use the real placement instead...
size_t compiler_lookup_section_placement(const TQLCompiler *compiler,
                                         Symbol symbol) {
  size_t placement = 0;
  for (size_t i = 0; i < compiler->section_table.len; i++) {
    if (compiler->section_table.data[i].symbol == symbol) {
      return placement;
    } else {
      placement += compiler->section_table.data[i].ops.len;
    }
  }
  assert(false && "Should not get here");
}

static inline Op assemble_op(TQLCompiler *compiler, const IrInstr *ir) {
  switch (ir->opcode) {
  case OP_NOOP:
    return op_noop();
  case OP_HALT:
    return op_halt();
  case OP_BRANCH: {
    Axis axis;
    switch (ir->data.axis.axis_type) {
    case AXIS_CHILD:
      axis = axis_child();
      break;
    case AXIS_DESCENDANT:
      axis = axis_descendant();
      break;
    case AXIS_FIELD: {
      const SymbolEntry *se =
          compiler_lookup_symbol(compiler, ir->data.axis.data.field);
      axis = axis_field(ts_language_field_id_for_name(
          compiler->target, se->slice.buf, se->slice.length));
    } break;
    case AXIS_VAR:
      axis = (Axis){.axis_type = AXIS_VAR,
                    .data = {.variable = ir->data.axis.data.variable}};
      break;
    }
    return op_branch(axis);
  }
  case OP_BIND:
    return op_bind(ir->data.variable);
  case OP_IF: {
    Predicate pred;
    switch (ir->data.predicate.predicate_type) {
    case PREDICATE_TEXTEQ:
      pred = predicate_texteq(ir->data.predicate.data.texteq.node_expression,
                              ir->data.predicate.data.texteq.text);
      break;
    case PREDICATE_TYPEEQ:
      pred = predicate_typeeq(
          ir->data.predicate.data.typeeq.node_expression,
          ts_language_symbol_for_name(
              compiler->target, ir->data.predicate.data.typeeq.type,
              strlen(ir->data.predicate.data.typeeq.type), true));
      break;
    }
    pred = ir->data.predicate.negate ? predicate_negate(pred) : pred;
    return op_if(pred);
  }
  case OP_YIELD:
    return op_yield();
  case OP_JMP: {
    Jump jump = jump_absolute(
        compiler_lookup_section_placement(compiler, ir->data.jump));
    return op_jump(jump);
  }
  case OP_PROBE: {
    Jump jump = jump_absolute(
        compiler_lookup_section_placement(compiler, ir->data.probe.jump));
    return op_probe((Probe){.mode = ir->data.probe.mode, .jump = jump});
  }
  case OP_PUSH:
    switch (ir->data.push_target) {
    case PUSH_NODE:
      return op_pushnode();
    case PUSH_PC:
      return op_pushpc();
    }
    return op_pushnode();
  case OP_POP:
    switch (ir->data.push_target) {
    case PUSH_NODE:
      return op_popnode();
    case PUSH_PC:
      return op_poppc();
    }
    break;
  case OP_CALL: {
    Jump jump = jump_absolute(
        compiler_lookup_section_placement(compiler, ir->data.jump));
    return op_call(jump);
  }
  case OP_RET:
    return op_ret();
  }
  assert(false);
}

Program tql_compiler_compile(TQLCompiler *compiler) {
  // IR emission phase
  {
    Symbol tramp_symbol = compiler_request_symbol(compiler);
    Symbol main_symbol =
        compiler_symbol_for_function(compiler, string_slice_from("main"));
    IrInstrs tramp_ops;
    ir_instrs_init(&tramp_ops);
    ir_instrs_append(&tramp_ops, ir_call(main_symbol));
    ir_instrs_append(&tramp_ops, ir_yield());
    ir_instrs_append(&tramp_ops, ir_halt());
    compiler_section_insert(compiler, tramp_symbol, &tramp_ops);
    ir_instrs_deinit(&tramp_ops);

    for (int i = 0; i < compiler->ast->tree->function_count; i++) {
      compile_tql_function(compiler, compiler->ast->tree->functions[i]);
    }
  }

  // Layout phase
  uint32_t sz = 0;
  uint32_t symbol_start = 0;
  uint32_t instr_start = 0;
  {
    // Calculate the necessary buffer size
    uint32_t offset = 0;

    symbol_start = offset;
    for (size_t i = 0; i < compiler->symbol_table->len; i++) {
      // FIXME: Further evidence we should be storing string sizes here...
      offset += compiler->symbol_table->data[i].slice.length + 1;
    }

    instr_start = offset;
    for (size_t i = 0; i < compiler->section_table.len; i++) {
      Section section = compiler->section_table.data[i];
      offset += section.ops.len * sizeof(Op);
    }

    sz = offset;
  }

  // Relocation phase
  char *buf = malloc(sz);
  {
    uint32_t offset = 0;
    for (size_t i = 0; i < compiler->symbol_table->len; i++) {
      SymbolEntry *entry = &compiler->symbol_table->data[i];
      entry->placement = offset;
      offset += entry->slice.length + 1;
    }

    for (size_t i = 0; i < compiler->section_table.len; i++) {
      Section *section = &compiler->section_table.data[i];
      section->placement = offset;
      offset += section->ops.len * sizeof(Op);
    }
  }

  // Patch phase
  {
    // Patch in symbols
    for (size_t i = 0; i < compiler->symbol_table->len; i++) {
      SymbolEntry *entry = &compiler->symbol_table->data[i];
      strncpy(buf + entry->placement, entry->slice.buf, entry->slice.length);
      *(buf + entry->placement + entry->slice.length) = '\0';
    }

    // Patch in IR -> Ops
    for (size_t i = 0; i < compiler->section_table.len; i++) {
      Section *section = &compiler->section_table.data[i];
      Op *placement = (Op *)(buf + section->placement);
      for (size_t j = 0; j < section->ops.len; j++) {
        Op op = assemble_op(compiler, &section->ops.data[j]);
        *placement++ = op;
      }
    }
  }

  return (Program){
      .version = 0x00000001,
      .target_language = compiler->target,
      // TODO: Use statics
      .statics = 0,
      .symbol_table = symbol_start,
      .entrypoint = instr_start,
      .endpoint = sz,
      .data = buf,
  };
}

const TSLanguage *tql_compiler_target(TQLCompiler *compiler) {
  return compiler->target;
}
