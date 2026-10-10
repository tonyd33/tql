//! A dictionary argument that every call of a function passes the same is
//! substituted into the function's body, and the parameter dropped.

const std = @import("std");
const core = @import("../core.zig");
const laws = @import("laws.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// What the calls of a function pass at one parameter.
const Passed = union(enum) {
    /// Only the parameter itself, from a recursive call, if anything.
    nothing,
    /// One closed dictionary, or the parameter itself.
    dictionary: core.Term,
    varies,
};

/// Substitutes the dictionaries of a program's functions.
///
/// A function is a global or a `let` or `letrec` binding whose value is a
/// lambda. Its parameter is substituted when every call outside the function
/// passes one closed dictionary there, and every call inside passes that or
/// the parameter itself. A function a law matches on, a join point, and one
/// named anywhere but at the head of a call keep every parameter. An
/// instance applied to dictionaries is a call of each method a law may
/// select from it.
///
/// Binders are unique, so one walk sees every call of every function.
pub const Substituter = struct {
    scratch: Allocator,
    builder: core.Builder,
    env: *core.env.Env,
    /// Each function's parameters.
    functions: core.SymbolTable([]const core.SymbolId),
    /// What every call passes, by parameter.
    passed: core.SymbolTable(Passed),

    pub fn init(scratch: Allocator, builder: core.Builder, env: *core.env.Env) Substituter {
        return .{
            .scratch = scratch,
            .builder = builder,
            .env = env,
            .functions = .init(scratch),
            .passed = .init(scratch),
        };
    }

    /// Substitute the dictionaries of `program`'s functions, in place.
    /// Returns whether a parameter was dropped.
    pub fn run(self: *Substituter, program: *core.Program) Error!bool {
        for (program.definitions) |d| try self.declare(d.symbol, d.body);
        for (program.definitions) |d| try self.calls(d.body);

        if (!self.drops()) return false;

        const definitions = try self.builder.slice(core.Definition, program.definitions.len);
        for (program.definitions, definitions) |old, *new| {
            new.* = .{ .symbol = old.symbol, .body = try self.bound(old.symbol, old.body), .span = old.span };
        }
        program.definitions = definitions;
        return true;
    }

    /// Whether any parameter is dropped.
    fn drops(self: *const Substituter) bool {
        var it = self.passed.iterator();
        while (it.next()) |entry| if (entry.value == .dictionary) return true;
        return false;
    }

    /// Record `name` as a function when `value` is a lambda and `name` may
    /// lose a parameter.
    fn declare(self: *Substituter, name: core.SymbolId, value: core.Term) Error!void {
        if (value.kind != .lambda) return;
        if (self.env.interner.details(name) == .join) return;
        if (laws.named(&self.env.interner, &self.env.classes, &self.env.known, name)) return;
        const parameters = try self.scratch.alloc(core.SymbolId, value.arity());
        _ = value.peel(parameters);
        for (parameters) |parameter| try self.passed.put(parameter, .nothing);
        try self.functions.put(name, parameters);
    }

    /// Record what each call in `t` passes, declaring each local function
    /// before the calls in its scope.
    fn calls(self: *Substituter, t: core.Term) Error!void {
        switch (t.kind) {
            .literal => {},
            .symbol => |id| self.call(id, &.{}),
            .apply => {
                const applications = try self.scratch.alloc(core.Term, t.spineLength());
                t.applications(applications);
                switch (t.head().kind) {
                    .symbol => |id| self.call(id, applications),
                    else => try self.calls(t.head()),
                }
                for (applications) |a| try self.calls(a.kind.apply.argument);
            },
            .lambda => |lambda| try self.calls(lambda.body),
            .case => |case_term| {
                try self.calls(case_term.scrutinee);
                for (case_term.alternatives) |alternative| try self.calls(alternative.body);
                if (case_term.default) |body| try self.calls(body);
            },
            .let => |let| {
                try self.declare(let.name, let.value);
                try self.calls(let.value);
                try self.calls(let.body);
            },
            .letrec => |letrec| {
                for (letrec.bindings) |binding| try self.declare(binding.name, binding.value);
                for (letrec.bindings) |binding| try self.calls(binding.value);
                try self.calls(letrec.body);
            },
        }
    }

    /// Record what `id`, applied by each of `applications`, is passed.
    fn call(self: *Substituter, id: core.SymbolId, applications: []const core.Term) void {
        for (laws.selectable(&self.env.interner, &self.env.classes, id)) |method| self.call(method, applications);
        const parameters = self.functions.get(id) orelse return;
        const applied = @min(parameters.len, applications.len);
        for (parameters[applied..]) |parameter| self.passed.getPtr(parameter).?.* = .varies;
        for (parameters[0..applied], applications[0..applied]) |parameter, a| {
            const argument = a.kind.apply.argument;
            if (argument.kind == .symbol and argument.kind.symbol == parameter) continue;
            const passed = self.passed.getPtr(parameter).?;
            if (!laws.closedDictionary(&self.env.interner, &self.env.classes, argument)) {
                passed.* = .varies;
                continue;
            }
            passed.* = switch (passed.*) {
                .nothing => .{ .dictionary = argument },
                .dictionary => |d| if (equal(d, argument)) passed.* else .varies,
                .varies => .varies,
            };
        }
    }

    /// The dictionary substituted for `parameter`, if it is dropped.
    fn replacement(self: *const Substituter, parameter: core.SymbolId) ?core.Term {
        return switch (self.passed.get(parameter) orelse return null) {
            .dictionary => |d| d,
            .nothing, .varies => null,
        };
    }

    /// The parameters of `name`, when it is a function that drops one.
    fn dropping(self: *const Substituter, name: core.SymbolId) ?[]const core.SymbolId {
        const parameters = self.functions.get(name) orelse return null;
        for (parameters) |parameter| if (self.replacement(parameter) != null) return parameters;
        return null;
    }

    /// `value`, bound to `name`, with its dropped parameters' lambdas removed
    /// and every term in it rewritten.
    fn bound(self: *Substituter, name: core.SymbolId, value: core.Term) Error!core.Term {
        const parameters = self.dropping(name) orelse return try self.rewrite(value);
        var kept: std.ArrayList(core.SymbolId) = .empty;
        for (parameters) |parameter| if (self.replacement(parameter) == null) try kept.append(self.scratch, parameter);
        return try self.builder.abstract(kept.items, try self.rewrite(value.underLambdas(parameters.len)));
    }

    /// `t` with each dropped parameter replaced, and each call missing the
    /// arguments its function dropped. Shares every subtree with nothing
    /// rewritten.
    fn rewrite(self: *Substituter, t: core.Term) Error!core.Term {
        switch (t.kind) {
            .literal => return t,
            .symbol => |id| return self.replacement(id) orelse t,
            .apply => |apply| {
                const head = t.head();
                if (head.kind == .symbol) {
                    if (self.dropping(head.kind.symbol)) |parameters| return try self.rewriteCall(t, parameters);
                }
                const function = try self.rewrite(apply.function);
                const argument = try self.rewrite(apply.argument);
                if (core.same(function, apply.function) and core.same(argument, apply.argument)) return t;
                return try self.builder.apply(function, argument, t.span);
            },
            .lambda => |lambda| {
                const body = try self.rewrite(lambda.body);
                if (core.same(body, lambda.body)) return t;
                return try self.builder.lambda(lambda.parameter, body, t.span);
            },
            .case => |case_term| {
                const scrutinee = try self.rewrite(case_term.scrutinee);
                var alternatives: core.Rebuilt(core.Case.Alternative) = .{ .original = case_term.alternatives };
                for (case_term.alternatives, 0..) |old, i| {
                    const body = try self.rewrite(old.body);
                    try alternatives.set(self.builder, i, .{
                        .constructor = old.constructor,
                        .binders = old.binders,
                        .body = body,
                    }, !core.same(body, old.body));
                }
                const default = if (case_term.default) |body| try self.rewrite(body) else null;
                if (alternatives.copy == null and core.same(scrutinee, case_term.scrutinee) and core.sameOptional(default, case_term.default)) return t;
                return try self.builder.caseWithDefault(scrutinee, alternatives.copy orelse case_term.alternatives, default, t.span);
            },
            .let => |let| {
                const value = try self.bound(let.name, let.value);
                const body = try self.rewrite(let.body);
                if (core.same(value, let.value) and core.same(body, let.body)) return t;
                return try self.builder.let(let.name, value, body, t.span);
            },
            .letrec => |letrec| {
                var bindings: core.Rebuilt(core.Letrec.Binding) = .{ .original = letrec.bindings };
                for (letrec.bindings, 0..) |old, i| {
                    const value = try self.bound(old.name, old.value);
                    try bindings.set(self.builder, i, .{ .name = old.name, .value = value }, !core.same(value, old.value));
                }
                const body = try self.rewrite(letrec.body);
                if (bindings.copy == null and core.same(body, letrec.body)) return t;
                return try self.builder.letrec(bindings.copy orelse letrec.bindings, body, t.span);
            },
        }
    }

    /// `t`, a call of a function with `parameters` that drops one, without
    /// the dropped arguments and with the rest rewritten.
    fn rewriteCall(self: *Substituter, t: core.Term, parameters: []const core.SymbolId) Error!core.Term {
        const applications = try self.scratch.alloc(core.Term, t.spineLength());
        t.applications(applications);
        var result = t.head();
        for (applications, 0..) |a, i| {
            if (i < parameters.len and self.replacement(parameters[i]) != null) continue;
            result = try self.builder.apply(result, try self.rewrite(a.kind.apply.argument), a.span);
        }
        return result;
    }
};

/// Whether `a` and `b` apply the same symbols in the same shape.
fn equal(a: core.Term, b: core.Term) bool {
    return switch (a.kind) {
        .symbol => |id| b.kind == .symbol and b.kind.symbol == id,
        .apply => |x| b.kind == .apply and equal(x.function, b.kind.apply.function) and equal(x.argument, b.kind.apply.argument),
        else => false,
    };
}
