//! Checked Core to the STG-shaped term language.
//!
//! Two things happen here:
//!
//! - Atomization: a compound argument is let-bound to a thunk before it is
//!   passed, so an application and a constructor take atoms only.
//! - Spine collection: Core applies one argument at a time, and a call site
//!   here carries its whole argument list.
//!
//! Binders are globally unique, interned once by resolution, so a name means
//! one binder wherever it appears and nothing here handles shadowing.

const std = @import("std");
const core = @import("../lang/core.zig");
const datatypes = @import("../lang/datatypes.zig");
const desugar = @import("../desugar.zig");
const free = @import("free.zig");
const primitives = @import("../lang/primitives.zig");
const stg = @import("stg.zig");
const symbols = @import("../lang/symbols.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{Unsupported};

/// What a Core symbol resolves to at a use site.
const Callee = union(enum) {
    local: symbols.SymbolId,
    global: symbols.SymbolId,
    constructor: *const datatypes.Constructor,
    primitive: primitives.Lowering,
};

/// Bindings an expression needed before it could be written, in allocation
/// order. Atomizing an argument appends here.
const Hoisted = std.ArrayList(stg.Binding);

pub const Translator = struct {
    arena: Allocator,
    gpa: Allocator,
    program: *const desugar.Program,
    /// Names for the thunks atomization introduces. From the interner, so they
    /// cannot collide with a source binder.
    interner: *symbols.Interner,
    generated: u32 = 0,

    /// Whether a symbol is a local rather than something reached by identity.
    pub fn isLocal(context: *const anyopaque, symbol: symbols.SymbolId) bool {
        const self: *const Translator = @ptrCast(@alignCast(context));
        if (self.program.datatypes.constructorOf(symbol) != null) return false;
        if (self.program.primitives.contains(symbol)) return false;
        // A synthesized symbol is reached by identity too. These are in the
        // synthesis table, not the primitive table; missing them here makes a
        // closure try to capture an operator.
        if (self.program.synthesis.get(symbol) != null) return false;
        for (self.program.definitions) |definition| {
            if (definition.symbol == symbol) return false;
        }
        return true;
    }

    fn resolve(self: *Translator, name: symbols.SymbolId) Callee {
        if (self.program.datatypes.constructorOf(name)) |constructor| {
            return .{ .constructor = constructor };
        }
        if (self.program.primitives.lowering(name)) |lowering| {
            return .{ .primitive = lowering };
        }
        // A synthesized symbol lowers like a primitive.
        if (self.program.synthesis.get(name)) |synthesis| {
            return .{ .primitive = switch (synthesis) {
                .kind_test => .is_kind,
                .field => .field,
                .operator => .operator,
                .record => .record,
            } };
        }
        for (self.program.definitions) |definition| {
            if (definition.symbol == name) return .{ .global = name };
        }
        return .{ .local = name };
    }

    /// Collect an application spine: `((f a) b) c` becomes `f` and `[a,b,c]`.
    fn spine(
        self: *Translator,
        term: core.Term,
        out: *std.ArrayList(core.Term),
    ) Allocator.Error!core.Term {
        var head = term;
        while (head.kind == .apply) {
            const apply = head.kind.apply;
            try out.insert(self.gpa, 0, apply.argument);
            head = apply.function;
        }
        return head;
    }

    /// Reduce a term to an atom, hoisting a thunk when it is not already one.
    ///
    /// A compound constructor field cannot reach the evaluator unatomized, so
    /// nothing downstream can build one that was evaluated eagerly.
    fn atomize(
        self: *Translator,
        term: core.Term,
        hoisted: *Hoisted,
    ) Error!stg.Atom {
        switch (term.kind) {
            .literal => |literal| return .{ .literal = literal },
            .symbol => |name| switch (self.resolve(name)) {
                .local => |id| return .{ .local = id },
                .global => |id| return .{ .global = id },
                .constructor => |c| {
                    // A nullary constructor is a value, allocated directly.
                    if (c.fields.len == 0) {
                        const allocated = try self.arena.create(stg.Constructed);
                        allocated.* = .{ .constructor = c.symbol, .tag = c.tag, .fields = &.{} };
                        return try self.bindConstructed(allocated, hoisted);
                    }
                    // One that still wants fields is a function. Desugaring
                    // applies every constructor to all of them, so nothing
                    // reaches this.
                    return error.Unsupported;
                },
                // A primitive passed as a value, as `select p = branch p
                // identity empty` passes both of its arms.
                .primitive => |lowering| {
                    const wrapper = try self.primitiveWrapper(name, lowering);
                    return try self.bindClosure(wrapper, hoisted);
                },
            },
            else => {},
        }

        // A thunk is a closure of no arguments.
        const thunk = try self.closure(&.{}, term, .updatable);
        return try self.bindClosure(thunk, hoisted);
    }

    /// A binder for something atomization introduced.
    ///
    /// The id is distinct whatever the spelling; the counter only keeps the
    /// printed term readable.
    fn freshBinder(self: *Translator, comptime prefix: []const u8) Error!symbols.SymbolId {
        // Wide enough for the prefix and any `u32`, so the format cannot fail.
        var buffer: [prefix.len + 10]u8 = undefined;
        const spelling = std.fmt.bufPrint(
            &buffer,
            prefix ++ "{d}",
            .{self.generated},
        ) catch return error.Unsupported;
        self.generated += 1;
        return try self.interner.fresh(spelling);
    }

    fn bindClosure(
        self: *Translator,
        allocated: *const stg.Closure,
        hoisted: *Hoisted,
    ) Error!stg.Atom {
        const binder = try self.freshBinder("t");
        try hoisted.append(self.gpa, .{ .binder = binder, .value = .{ .closure = allocated } });
        return .{ .local = binder };
    }

    fn bindConstructed(
        self: *Translator,
        allocated: *const stg.Constructed,
        hoisted: *Hoisted,
    ) Error!stg.Atom {
        const binder = try self.freshBinder("c");
        try hoisted.append(self.gpa, .{ .binder = binder, .value = .{ .constructed = allocated } });
        return .{ .local = binder };
    }

    /// Translate a term, wrapping whatever atomization had to hoist.
    fn expression(self: *Translator, term: core.Term) Error!stg.Expr {
        var hoisted: Hoisted = .empty;
        defer hoisted.deinit(self.gpa);

        const body = try self.open(term, &hoisted);
        return try self.close(body, &hoisted);
    }

    /// Wrap `body` in a `let` for each binding atomization hoisted.
    fn close(self: *Translator, body: stg.Expr, hoisted: *Hoisted) Error!stg.Expr {
        if (hoisted.items.len == 0) return body;

        const let = try self.arena.create(stg.Expr.Let);
        let.* = .{
            .bindings = try self.arena.dupe(stg.Binding, hoisted.items),
            .recursive = false,
            .body = body,
        };
        return .{ .let = let };
    }

    /// Translate a term into the caller's hoist list, so an atomized argument
    /// binds outside the expression that uses it.
    fn open(self: *Translator, term: core.Term, hoisted: *Hoisted) Error!stg.Expr {
        switch (term.kind) {
            .literal => |literal| return .{ .atom = .{ .literal = literal } },

            .symbol => return .{ .atom = try self.atomize(term, hoisted) },

            .apply => {
                var arguments: std.ArrayList(core.Term) = .empty;
                defer arguments.deinit(self.gpa);
                const head = try self.spine(term, &arguments);

                const atoms = try self.arena.alloc(stg.Atom, arguments.items.len);
                for (arguments.items, atoms) |argument, *atom| {
                    atom.* = try self.atomize(argument, hoisted);
                }

                return try self.call(head, atoms, hoisted);
            },

            .lambda => {
                // Collect the whole parameter list: `\x -> \y -> e` is one
                // closure of arity two, not two of arity one.
                var parameters: std.ArrayList(symbols.SymbolId) = .empty;
                defer parameters.deinit(self.gpa);

                var body = term;
                while (body.kind == .lambda) {
                    try parameters.append(self.gpa, body.kind.lambda.parameter);
                    body = body.kind.lambda.body;
                }

                const allocated = try self.closure(parameters.items, body, .single_entry);
                return .{ .atom = try self.bindClosure(allocated, hoisted) };
            },

            .case => |case_term| {
                const scrutinee = try self.open(case_term.scrutinee, hoisted);

                const alternatives = try self.arena.alloc(stg.Alternative, case_term.alternatives.len);
                for (case_term.alternatives, alternatives) |source, *alternative| {
                    const constructor = self.program.datatypes.constructorOf(source.constructor) orelse
                        return error.Unsupported;
                    alternative.* = .{
                        .constructor = source.constructor,
                        .tag = constructor.tag,
                        .binders = try self.arena.dupe(symbols.SymbolId, source.binders),
                        .body = try self.expression(source.body),
                    };
                }

                const node = try self.arena.create(stg.Expr.Case);
                node.* = .{ .scrutinee = scrutinee, .alternatives = alternatives };
                return .{ .case = node };
            },

            .letrec => |letrec| {
                const bindings = try self.arena.alloc(stg.Binding, letrec.bindings.len);
                for (letrec.bindings, bindings) |source, *binding| {
                    binding.* = .{
                        .binder = source.name,
                        .value = .{ .closure = try self.closure(&.{}, source.value, .updatable) },
                    };
                }

                const node = try self.arena.create(stg.Expr.Let);
                node.* = .{
                    .bindings = bindings,
                    .recursive = true,
                    .body = try self.expression(letrec.body),
                };
                return .{ .let = node };
            },

            .bind => |bind_term| {
                // `bind x <- v in body` is `flat_map v (\x -> body)`, an
                // ordinary call. The evaluator never sees a bind.
                const flat_map = self.program.interner.lookup("flat_map") orelse
                    return error.Unsupported;

                const source = try self.atomize(bind_term.value, hoisted);
                const receiver = try self.closure(
                    &.{bind_term.name},
                    bind_term.body,
                    .single_entry,
                );

                const arguments = try self.arena.alloc(stg.Atom, 2);
                arguments[0] = source;
                arguments[1] = try self.bindClosure(receiver, hoisted);

                const node = try self.arena.create(stg.Expr.Apply);
                node.* = .{ .callee = .{ .global = flat_map }, .arguments = arguments };
                return .{ .apply = node };
            },
        }
    }

    /// Emit a call, dispatching on what the head resolved to.
    fn call(
        self: *Translator,
        head: core.Term,
        arguments: []const stg.Atom,
        hoisted: *Hoisted,
    ) Error!stg.Expr {
        if (head.kind == .symbol) {
            switch (self.resolve(head.kind.symbol)) {
                .constructor => |c| {
                    // An unsaturated constructor would need a wrapper closure.
                    // Desugaring emits every constructor applied to all its
                    // fields, so nothing produces one.
                    if (c.fields.len != arguments.len) return error.Unsupported;
                    const node = try self.arena.create(stg.Constructed);
                    node.* = .{
                        .constructor = c.symbol,
                        .tag = c.tag,
                        .fields = arguments,
                    };
                    return .{ .constructed = node };
                },
                .primitive => |lowering| {
                    // A primitive node is saturated by construction, so the
                    // evaluator runs it without an arity check. An
                    // under-applied one becomes a call to its wrapper.
                    const wanted = try self.primitiveArity(head.kind.symbol);
                    if (arguments.len == wanted) {
                        const node = try self.arena.create(stg.Expr.Primitive);
                        node.* = .{
                            .lowering = lowering,
                            .symbol = head.kind.symbol,
                            .arguments = arguments,
                        };
                        return .{ .primitive = node };
                    }

                    const wrapper = try self.primitiveWrapper(head.kind.symbol, lowering);
                    const node = try self.arena.create(stg.Expr.Apply);
                    node.* = .{
                        .callee = try self.bindClosure(wrapper, hoisted),
                        .arguments = arguments,
                    };
                    return .{ .apply = node };
                },
                else => {},
            }
        }

        const node = try self.arena.create(stg.Expr.Apply);
        node.* = .{
            .callee = try self.atomize(head, hoisted),
            .arguments = arguments,
        };
        return .{ .apply = node };
    }

    /// How many arguments a primitive's denotation takes: the arrow count of
    /// its declared scheme. `Filter a b` is `a -> [b]`, so a filter-typed
    /// primitive counts its input, making `pure` arity two.
    fn primitiveArity(self: *Translator, name: symbols.SymbolId) Error!u32 {
        // A synthesized symbol has no row in the primitive table.
        if (self.program.synthesis.get(name)) |synthesis| {
            return switch (synthesis) {
                // `is_kind[k]` and `field[l]` are `Filter Node Node`, one
                // argument; an operator takes two scalars.
                .kind_test, .field => 1,
                .operator => 2,
                .record => |labels| @intCast(labels.len),
            };
        }

        const scheme = self.program.primitives.scheme(name) orelse return error.Unsupported;
        var arity: u32 = 0;
        var walk = scheme.type;
        while (walk == .function) : (walk = walk.function.to) arity += 1;
        return arity;
    }

    /// Wrap a primitive in a closure that applies it, so it can be passed as a
    /// value.
    fn primitiveWrapper(
        self: *Translator,
        name: symbols.SymbolId,
        lowering: primitives.Lowering,
    ) Error!*const stg.Closure {
        const arity = try self.primitiveArity(name);
        if (arity == 0) return error.Unsupported;

        const parameters = try self.arena.alloc(symbols.SymbolId, arity);
        const arguments = try self.arena.alloc(stg.Atom, arity);
        for (parameters, arguments) |*parameter, *argument| {
            parameter.* = try self.freshBinder("p");
            argument.* = .{ .local = parameter.* };
        }

        const call_node = try self.arena.create(stg.Expr.Primitive);
        call_node.* = .{ .lowering = lowering, .symbol = name, .arguments = arguments };

        const node = try self.arena.create(stg.Closure);
        node.* = .{
            .free = &.{},
            .update = .single_entry,
            .parameters = parameters,
            .body = .{ .primitive = call_node },
        };
        return node;
    }

    /// Build a closure over `body`, collecting the free variables it reads.
    fn closure(
        self: *Translator,
        parameters: []const symbols.SymbolId,
        body: core.Term,
        update: stg.Update,
    ) Error!*const stg.Closure {
        var collector: free.Collector = .{
            .gpa = self.gpa,
            .is_local = isLocal,
            .context = self,
        };
        defer collector.deinit();

        for (parameters) |parameter| try collector.bound.append(self.gpa, parameter);
        try collector.walk(body);

        const node = try self.arena.create(stg.Closure);
        node.* = .{
            .free = try self.arena.dupe(symbols.SymbolId, collector.out.items),
            .update = update,
            .parameters = try self.arena.dupe(symbols.SymbolId, parameters),
            .body = try self.expression(body),
        };
        return node;
    }
};

/// Translate a checked program into the STG-shaped term language.
///
/// The returned Program owns its arena and is deinitialized independently of
/// the desugar.Program it came from.
pub fn translate(
    gpa: Allocator,
    program: *desugar.Program,
) Error!stg.Program {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    var translator: Translator = .{
        .arena = arena.allocator(),
        .gpa = gpa,
        .program = program,
        .interner = &program.interner,
    };

    const definitions = try arena.allocator().alloc(stg.Definition, program.definitions.len);
    for (program.definitions, definitions) |source, *definition| {
        definition.* = .{
            .symbol = source.symbol,
            .value = try translator.closure(&.{}, source.body, .updatable),
        };
    }

    return .{
        .definitions = definitions,
        .entry = program.entry,
        .arena = arena,
    };
}
