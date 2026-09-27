//! Lowering: checked Core to STG terms.

const free = @import("core_to_stg/free.zig");
const translate_mod = @import("core_to_stg/translate.zig");

/// Translates a checked program into the term language.
pub const translate = translate_mod.translate;

/// One program's translation state.
pub const Translator = translate_mod.Translator;

pub const Error = translate_mod.Error;

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(free);
    refAllDecls(translate_mod);
}
