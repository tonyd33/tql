pub const CompilerError = error{
    OutOfMemory,
    PCRE2Unknown,
    UnresolvedLabel,
    InvalidLabelReference,
    InvalidVariableReference,
};
