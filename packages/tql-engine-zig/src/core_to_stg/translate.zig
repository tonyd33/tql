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
const core = @import("../core.zig");
const free = @import("free.zig");
const primitives = @import("../primitives.zig");
const pcre2 = @import("../regex.zig");
const stg = @import("../stg.zig");
const datatypes = core.datatypes;

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    Unsupported,
    /// A regex pattern failed to compile. Desugaring validated every one, so
    /// this is not reached by a query that checked.
    InvalidRegex,
    /// A local name no enclosing binder introduced. The free-variable pass
    /// captures every such name, so this is not reached by a checked query.
    UnboundLocal,
};

/// What a Core symbol resolves to at a use site.
const Callee = union(enum) {
    local: core.SymbolId,
    global: stg.Global,
    constructor: *const datatypes.Constructor,
    primitive: core.PrimOp,
};

/// Bindings an expression needed before it could be written, in allocation
/// order. Atomizing an argument appends here.
const Hoisted = std.ArrayList(stg.Binding);

pub const Translator = struct {
    arena: Allocator,
    gpa: Allocator,
    program: *const core.Program,
    /// Names for the thunks atomization introduces. From the interner, so they
    /// cannot collide with a source binder.
    interner: *core.Interner,
    generated: u32 = 0,

    /// The environment of the closure being translated, in the order the
    /// evaluator builds it: captured free variables, then the frame.
    ///
    /// Nothing here is searched at run time; this pass turns every name into
    /// an offset into it.
    scope: std.ArrayList(core.SymbolId) = .empty,

    /// Every regex literal compiled so far. The caller frees their programs.
    regexes: std.ArrayList(*stg.Regex) = .empty,

    /// Each top-level definition's position in `program.definitions`.
    indices: core.SymbolTable(u32),

    pub fn init(arena: Allocator, gpa: Allocator, program: *core.Program) Allocator.Error!Translator {
        var indices = core.SymbolTable(u32).init(gpa);
        errdefer indices.deinit();
        for (program.definitions, 0..) |definition, i| try indices.put(definition.symbol, @intCast(i));
        return .{
            .arena = arena,
            .gpa = gpa,
            .program = program,
            .interner = &program.env.interner,
            .indices = indices,
        };
    }

    /// Frees the translator's own tables. The regex programs it compiled are
    /// the caller's.
    pub fn deinit(self: *Translator) void {
        self.indices.deinit();
        self.regexes.deinit(self.gpa);
    }

    /// What `name` denotes if it is synthesized, copied into the program.
    fn synthesized(self: *Translator, name: core.SymbolId) Error!?core.Synthesized {
        const source = switch (self.program.env.interner.details(name)) {
            .synthesized => |s| s,
            else => return null,
        };
        return switch (source) {
            .field => |f| .{ .field = .{
                .name = try self.arena.dupe(u8, f.name),
                .id = f.id,
            } },
            .operator => source,
            .record => |labels| blk: {
                const copies = try self.arena.alloc([]const u8, labels.len);
                for (labels, copies) |label, *copy| copy.* = try self.arena.dupe(u8, label);
                break :blk .{ .record = copies };
            },
            .select => |label| .{ .select = try self.arena.dupe(u8, label) },
        };
    }

    /// Lower a Core literal to its evaluated thunk, compiling a regex pattern
    /// into the program.
    fn literal(self: *Translator, source: core.Literal) Error!*stg.Thunk {
        const thunk = try self.arena.create(stg.Thunk);
        thunk.* = stg.Thunk.value(switch (source) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = try self.arena.dupe(u8, s) },
            .regex => |pattern| blk: {
                try self.regexes.ensureUnusedCapacity(self.gpa, 1);
                const regex = try self.arena.create(stg.Regex);
                regex.* = .{
                    .pattern = try self.arena.dupe(u8, pattern),
                    .compiled = pcre2.Regex.compile(pattern) catch return error.InvalidRegex,
                };
                self.regexes.appendAssumeCapacity(regex);
                break :blk .{ .regex = regex };
            },
            .kind => |k| .{ .kind = .{ .name = try self.arena.dupe(u8, k.name), .id = k.id } },
        });
        return thunk;
    }

    /// `name` as a global atom, if it is a top-level definition.
    fn global(self: *const Translator, name: core.SymbolId) ?stg.Global {
        const index = self.indices.get(name) orelse return null;
        return .{ .index = index, .symbol = name };
    }

    /// Where `name` sits in the environment of the closure being translated.
    fn place(self: *Translator, name: core.SymbolId) Error!stg.Local {
        // Innermost first, so the scope reads as a stack.
        var i = self.scope.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope.items[i] == name) {
                return .{ .offset = @intCast(i), .name = name };
            }
        }
        // Reached only for a name no enclosing binder introduced, which the
        // free-variable pass would have captured.
        return error.UnboundLocal;
    }

    /// Whether a symbol is a local rather than something reached by identity.
    pub fn isLocal(context: *const anyopaque, symbol: core.SymbolId) bool {
        const self: *const Translator = @ptrCast(@alignCast(context));
        // A constructor, primitive or synthesized symbol is reached by
        // identity. Missing one here makes a closure try to capture it.
        switch (self.program.env.interner.details(symbol)) {
            .constructor, .primop, .synthesized => return false,
            .vanilla => {},
        }
        return self.global(symbol) == null;
    }

    fn resolve(self: *Translator, name: core.SymbolId) Callee {
        switch (self.program.env.interner.details(name)) {
            .constructor => |c| return .{
                .constructor = &self.program.env.datatypes.get(c.owner).constructors[c.tag],
            },
            .primop => |primop| return .{ .primitive = primop },
            // A synthesized symbol lowers like a primitive.
            .synthesized => |s| return .{ .primitive = s.primop() },
            .vanilla => {},
        }
        if (self.global(name)) |g| return .{ .global = g };
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
            .literal => |source| return .{ .literal = try self.literal(source) },
            .symbol => |name| switch (self.resolve(name)) {
                .local => |id| return .{ .local = try self.place(id) },
                .global => |id| return .{ .global = id },
                .constructor => |c| {
                    // A nullary constructor is a value, allocated directly.
                    if (c.fields.len == 0) {
                        const allocated = try self.arena.create(stg.Constructed);
                        allocated.* = .{ .constructor = c.symbol, .tag = c.tag, .fields = &.{} };
                        return try self.bindConstructed(allocated, hoisted);
                    }
                    // One that still wants fields is a function.
                    return try self.bindClosure(try self.constructorWrapper(c), hoisted);
                },
                // A primitive passed as a value, as `select p = branch p
                // identity empty` passes both of its arms.
                .primitive => |primop| {
                    const wrapper = try self.primitiveWrapper(name, primop);
                    return try self.bindClosure(wrapper, hoisted);
                },
            },
            else => {},
        }

        // A thunk is a closure of no arguments.
        const thunk = try self.closure(&.{}, term);
        return try self.bindClosure(thunk, hoisted);
    }

    /// A binder for something atomization introduced.
    ///
    /// The id is distinct whatever the spelling; the counter only keeps the
    /// printed term readable.
    fn freshBinder(self: *Translator, comptime prefix: []const u8) Error!core.SymbolId {
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
        return .{ .local = try self.hoistedPlace(binder) };
    }

    fn bindConstructed(
        self: *Translator,
        allocated: *const stg.Constructed,
        hoisted: *Hoisted,
    ) Error!stg.Atom {
        const binder = try self.freshBinder("c");
        try hoisted.append(self.gpa, .{ .binder = binder, .value = .{ .constructed = allocated } });
        return .{ .local = try self.hoistedPlace(binder) };
    }

    /// Put a hoisted binder in scope and return its place.
    ///
    /// `close` wraps these in a non-recursive `let` around the body, so the
    /// evaluator appends them to the frame in the order they were hoisted,
    /// before evaluating the body that reads them.
    fn hoistedPlace(self: *Translator, binder: core.SymbolId) Error!stg.Local {
        const offset = self.scope.items.len;
        try self.scope.append(self.gpa, binder);
        return .{ .offset = @intCast(offset), .name = binder };
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
            .literal => |source| return .{ .atom = .{ .literal = try self.literal(source) } },

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

            .lambda => return .{ .atom = try self.bindClosure(try self.closureOf(term), hoisted) },

            .case => |case_term| {
                const scrutinee = try self.open(case_term.scrutinee, hoisted);

                const alternatives = try self.arena.alloc(stg.Alternative, case_term.alternatives.len);
                for (case_term.alternatives, alternatives) |source, *alternative| {
                    const constructor = self.program.env.datatypes.constructorOf(
                        &self.program.env.interner,
                        source.constructor,
                    ) orelse return error.Unsupported;
                    const binders = try self.arena.dupe(core.SymbolId, source.binders);

                    // In scope for this alternative's body only, and pushed in
                    // the order the evaluator binds the constructor's fields.
                    const mark = self.scope.items.len;
                    try self.scope.appendSlice(self.gpa, binders);
                    defer self.scope.shrinkRetainingCapacity(mark);

                    alternative.* = .{
                        .constructor = source.constructor,
                        .tag = constructor.tag,
                        .binders = binders,
                        .body = try self.expression(source.body),
                    };
                }

                const node = try self.arena.create(stg.Expr.Case);
                node.* = .{ .scrutinee = scrutinee, .alternatives = alternatives };
                return .{ .case = node };
            },

            .letrec => |letrec| {
                const bindings = try self.arena.alloc(stg.Binding, letrec.bindings.len);

                // Recursive: every binder is in scope for every right-hand
                // side as well as the body, and the evaluator appends them all
                // before filling any.
                const mark = self.scope.items.len;
                for (letrec.bindings) |source| {
                    try self.scope.append(self.gpa, source.name);
                }
                defer self.scope.shrinkRetainingCapacity(mark);

                for (letrec.bindings, bindings) |source, *binding| {
                    binding.* = .{
                        .binder = source.name,
                        .value = .{ .closure = try self.closureOf(source.value) },
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
                // `bind x <- v in body` is `concat_map (\x -> body) v`, an
                // ordinary call. The evaluator never sees a bind.
                const concat_map = self.program.env.interner.lookup(.prelude, "concat_map") orelse
                    return error.Unsupported;

                const source = try self.atomize(bind_term.value, hoisted);
                const receiver = try self.closure(&.{bind_term.name}, bind_term.body);

                const arguments = try self.arena.alloc(stg.Atom, 2);
                arguments[0] = try self.bindClosure(receiver, hoisted);
                arguments[1] = source;

                const node = try self.arena.create(stg.Expr.Apply);
                node.* = .{
                    .callee = .{ .global = self.global(concat_map) orelse return error.Unsupported },
                    .arguments = arguments,
                };
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
                    if (c.fields.len == arguments.len) {
                        const node = try self.arena.create(stg.Constructed);
                        node.* = .{
                            .constructor = c.symbol,
                            .tag = c.tag,
                            .fields = arguments,
                        };
                        return .{ .constructed = node };
                    }

                    // An under-applied constructor becomes a call to its
                    // wrapper.
                    const node = try self.arena.create(stg.Expr.Apply);
                    node.* = .{
                        .callee = try self.bindClosure(try self.constructorWrapper(c), hoisted),
                        .arguments = arguments,
                    };
                    return .{ .apply = node };
                },
                .primitive => |primop| {
                    // A primitive node is saturated by construction, so the
                    // evaluator runs it without an arity check. An
                    // under-applied one becomes a call to its wrapper.
                    const wanted = try self.primitiveArity(head.kind.symbol);
                    if (arguments.len == wanted) {
                        const node = try self.arena.create(stg.Expr.Primitive);
                        node.* = .{
                            .primop = primop,
                            .symbol = head.kind.symbol,
                            .synthesized = try self.synthesized(head.kind.symbol),
                            .arguments = arguments,
                        };
                        return .{ .primitive = node };
                    }

                    const wrapper = try self.primitiveWrapper(head.kind.symbol, primop);
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
    fn primitiveArity(self: *Translator, name: core.SymbolId) Error!u32 {
        // A synthesized symbol has no row in the primitive table.
        switch (self.program.env.interner.details(name)) {
            // `field[l]` is `Filter Node Node` and `select[l]` takes the
            // record, one argument each; an operator takes two scalars.
            .synthesized => |s| return switch (s) {
                .field, .select => 1,
                .operator => 2,
                .record => |labels| @intCast(labels.len),
            },
            else => {},
        }

        const scheme = self.program.env.schemeOf(name) orelse return error.Unsupported;
        var arity: u32 = 0;
        var walk = scheme.type;
        while (walk == .function) : (walk = walk.function.to) arity += 1;
        return arity;
    }

    /// Wrap a primitive in a closure that applies it, so it can be passed as a
    /// value.
    fn primitiveWrapper(
        self: *Translator,
        name: core.SymbolId,
        primop: core.PrimOp,
    ) Error!*const stg.Closure {
        const arity = try self.primitiveArity(name);
        if (arity == 0) return error.Unsupported;

        const parameters = try self.arena.alloc(core.SymbolId, arity);
        const arguments = try self.arena.alloc(stg.Atom, arity);
        // No free variables, so the frame is exactly the parameters and each
        // one's offset is its position.
        for (parameters, arguments, 0..) |*parameter, *argument, i| {
            parameter.* = try self.freshBinder("p");
            argument.* = .{ .local = .{ .offset = @intCast(i), .name = parameter.* } };
        }

        const call_node = try self.arena.create(stg.Expr.Primitive);
        call_node.* = .{
            .primop = primop,
            .symbol = name,
            .synthesized = try self.synthesized(name),
            .arguments = arguments,
        };

        const node = try self.arena.create(stg.Closure);
        node.* = .{
            .free = &.{},
            .parameters = parameters,
            .body = .{ .primitive = call_node },
        };
        return node;
    }

    /// Wrap a constructor with fields in a closure that builds it, so it can
    /// be passed as a value or applied to fewer than all its fields.
    fn constructorWrapper(
        self: *Translator,
        c: *const datatypes.Constructor,
    ) Error!*const stg.Closure {
        const parameters = try self.arena.alloc(core.SymbolId, c.fields.len);
        const fields = try self.arena.alloc(stg.Atom, c.fields.len);
        // No free variables, so the frame is exactly the parameters and each
        // one's offset is its position.
        for (parameters, fields, 0..) |*parameter, *field, i| {
            parameter.* = try self.freshBinder("f");
            field.* = .{ .local = .{ .offset = @intCast(i), .name = parameter.* } };
        }

        const constructed = try self.arena.create(stg.Constructed);
        constructed.* = .{ .constructor = c.symbol, .tag = c.tag, .fields = fields };

        const node = try self.arena.create(stg.Closure);
        node.* = .{
            .free = &.{},
            .parameters = parameters,
            .body = .{ .constructed = constructed },
        };
        return node;
    }

    /// The closure allocating `term` builds: for a lambda, a function taking
    /// its whole parameter list, so `\x -> \y -> e` has arity two; otherwise
    /// a thunk.
    fn closureOf(self: *Translator, term: core.Term) Error!*const stg.Closure {
        if (term.kind != .lambda) return try self.closure(&.{}, term);

        var parameters: std.ArrayList(core.SymbolId) = .empty;
        defer parameters.deinit(self.gpa);

        var body = term;
        while (body.kind == .lambda) {
            try parameters.append(self.gpa, body.kind.lambda.parameter);
            body = body.kind.lambda.body;
        }
        return try self.closure(parameters.items, body);
    }

    /// Build a closure over `body`, collecting the free variables it reads.
    fn closure(
        self: *Translator,
        parameters: []const core.SymbolId,
        body: core.Term,
    ) Error!*const stg.Closure {
        var collector: free.Collector = .{
            .gpa = self.gpa,
            .is_local = isLocal,
            .context = self,
        };
        defer collector.deinit();

        for (parameters) |parameter| try collector.bound.append(self.gpa, parameter);
        try collector.walk(body);

        const free_names = collector.out.items;
        const parameter_names = try self.arena.dupe(core.SymbolId, parameters);

        // Where each free variable sits in the *enclosing* environment, which
        // is what the evaluator copies from. Resolved before the scope is
        // switched, because that is the scope they name.
        const captures = try self.arena.alloc(stg.Local, free_names.len);
        for (free_names, captures) |name, *capture| capture.* = try self.place(name);

        // The body is translated in this closure's scope, not the enclosing
        // one: a reference means an offset, and the offsets differ per
        // closure. Saved and restored so a nested closure does not disturb
        // the one that contains it.
        const outer = self.scope;
        self.scope = .empty;
        defer {
            self.scope.deinit(self.gpa);
            self.scope = outer;
        }
        try self.scope.appendSlice(self.gpa, free_names);
        try self.scope.appendSlice(self.gpa, parameter_names);

        const node = try self.arena.create(stg.Closure);
        node.* = .{
            .free = captures,
            .parameters = parameter_names,
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
    program: *core.Program,
) Error!stg.Program {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    var translator = try Translator.init(arena.allocator(), gpa, program);
    defer translator.deinit();
    errdefer for (translator.regexes.items) |regex| regex.compiled.deinit();

    const definitions = try arena.allocator().alloc(stg.Definition, program.definitions.len);
    for (program.definitions, definitions) |source, *definition| {
        translator.generated = 0;
        definition.* = .{
            .symbol = source.symbol,
            .value = try translator.closure(&.{}, source.body),
        };
    }

    const registry = &program.env.datatypes;
    const nil = builtin(registry.nilConstructor());
    const nil_thunk = try arena.allocator().create(stg.Thunk);
    nil_thunk.* = stg.Thunk.value(.{ .constructed = .{
        .constructor = nil.symbol,
        .tag = nil.tag,
        .len = 0,
        .storage = undefined,
    } });
    return .{
        .definitions = definitions,
        .entry = program.entry,
        .structural = .{
            .nil = nil,
            .cons = builtin(registry.consConstructor()),
            .false_ = builtin(registry.boolConstructor(false)),
            .true_ = builtin(registry.boolConstructor(true)),
        },
        .nil = nil_thunk,
        .arena = arena,
        .regexes = try arena.allocator().dupe(*stg.Regex, translator.regexes.items),
    };
}

fn builtin(constructor: datatypes.Constructor) stg.Builtin {
    return .{ .symbol = constructor.symbol, .tag = constructor.tag };
}
