//! A dictionary argument that every call of a function passes the same is
//! substituted into the function's body, and the parameter dropped.

const std = @import("std");
const core = @import("../core.zig");
const laws = @import("laws.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error;

/// What the calls of a function pass at one parameter.
const Passed = union(enum) {
    /// No call passes a value known so far.
    nothing,
    /// One closed dictionary.
    dictionary: core.Term,
    varies,

    /// Returns what a parameter passed both `self` and `other` is passed.
    fn join(self: Passed, other: Passed) Passed {
        return switch (self) {
            .nothing => other,
            .varies => .varies,
            .dictionary => |d| switch (other) {
                .nothing => self,
                .dictionary => |e| if (equal(d, e)) self else .varies,
                .varies => .varies,
            },
        };
    }
};

/// One argument a call passes at a parameter.
const Argument = struct { parameter: core.SymbolId, term: core.Term };

/// Substitutes the dictionaries of a program's functions.
///
/// A function is a global or a `let` or `letrec` binding whose value is a
/// lambda. Its parameter is substituted when every call passes one closed
/// dictionary there, counting a parameter passed on as the dictionary it is
/// substituted by, and an instance applied to parameters as that instance
/// applied to theirs. A function a law matches on, a join point, and one
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
    /// Every argument a call passes at a function's parameter.
    arguments: std.ArrayList(Argument) = .empty,

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
        try self.solve();

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
            .symbol => |id| try self.call(id, &.{}),
            .apply => {
                const applications = try self.scratch.alloc(core.Term, t.spineLength());
                t.applications(applications);
                switch (t.head().kind) {
                    .symbol => |id| try self.call(id, applications),
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
    fn call(self: *Substituter, id: core.SymbolId, applications: []const core.Term) Error!void {
        for (laws.selectable(&self.env.interner, &self.env.classes, id)) |method| try self.call(method, applications);
        const parameters = self.functions.get(id) orelse return;
        const applied = @min(parameters.len, applications.len);
        for (parameters[applied..]) |parameter| self.passed.getPtr(parameter).?.* = .varies;
        for (parameters[0..applied], applications[0..applied]) |parameter, a| {
            try self.arguments.append(self.scratch, .{ .parameter = parameter, .term = a.kind.apply.argument });
        }
    }

    /// Join what each argument passes into its parameter, until nothing
    /// changes.
    fn solve(self: *Substituter) Error!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.arguments.items) |argument| {
                const passed = self.passed.getPtr(argument.parameter).?;
                const joined = passed.join(try self.passing(argument.term));
                if (std.meta.activeTag(joined) == std.meta.activeTag(passed.*)) continue;
                passed.* = joined;
                changed = true;
            }
        }
    }

    /// What passing `t` passes, given what each parameter is passed so far.
    fn passing(self: *Substituter, t: core.Term) Error!Passed {
        if (t.kind == .symbol) {
            if (self.passed.get(t.kind.symbol)) |passed| return passed;
        }
        if (laws.appliedInstance(&self.env.interner, &self.env.classes, t) == null) return .varies;
        const applications = try self.scratch.alloc(core.Term, t.spineLength());
        t.applications(applications);
        var result = t.head();
        var rebuilt = false;
        for (applications) |a| {
            const argument = a.kind.apply.argument;
            const dictionary = switch (try self.passing(argument)) {
                .dictionary => |d| d,
                .nothing => return .nothing,
                .varies => return .varies,
            };
            rebuilt = rebuilt or !core.same(dictionary, argument);
            result = try self.builder.apply(result, dictionary, a.span);
        }
        return .{ .dictionary = if (rebuilt) result else t };
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
            .lambda, .case => return try core.mapChildren(self.builder, t, self, rewrite),
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
