//! PartiQL lexer for DynamoDB (v0.2.4).
//!
//! The grammar surface AWS supports is small: SELECT / INSERT / UPDATE
//! / DELETE statements with a SQL-shaped WHERE clause and `?` positional
//! parameters. This file tokenises the input; `parser.zig` consumes the
//! token stream and produces a `Statement` AST that delegates to the
//! existing ConditionExpression / UpdateExpression evaluators for the
//! actual predicate / SET logic.
//!
//! Identifiers come in two flavours:
//!   - Quoted (`"col"`): case-sensitive, used verbatim.
//!   - Unquoted (`col`): case-folded to lowercase to match AWS.
//!
//! Reserved-word check (the DDB 573-word list) is *not* applied here.
//! That list governs only ConditionExpression / UpdateExpression bare
//! identifiers; inside PartiQL statements, double-quoted names are the
//! escape and unquoted names are subject only to the SQL keyword set
//! enforced via the keyword recogniser below.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenKind = enum {
    // Statement keywords
    kw_select,
    kw_from,
    kw_where,
    kw_insert,
    kw_into,
    kw_value,
    kw_values, // accepted as alias for VALUE
    kw_update,
    kw_set,
    kw_delete,
    kw_returning,
    // Logical / operator keywords
    kw_and,
    kw_or,
    kw_not,
    kw_between,
    kw_in,
    kw_is,
    kw_null,
    kw_true,
    kw_false,
    // RETURNING modifiers
    kw_all,
    kw_modified,
    kw_old,
    kw_new,
    // Identifiers + literals
    identifier, // unquoted (case-folded)
    quoted_identifier, // "..."
    string_literal, // '...'
    number_literal,
    question, // positional parameter
    // Operators / punctuation
    eq, // =
    neq, // <> or !=
    lt,
    le,
    gt,
    ge,
    plus,
    minus,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    dot,
    colon,
    star,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    /// Source-text view; for identifiers/literals this is the underlying
    /// text minus any quotes. For numeric literals it's the raw digits.
    text: []const u8,
    /// Byte offset in the original input. Helps with error messages.
    offset: usize,
};

pub const LexError = error{
    UnterminatedString,
    UnterminatedQuotedIdentifier,
    InvalidCharacter,
    OutOfMemory,
};

/// Tokenise the entire input. Allocates the returned slice + interns
/// quoted-string-content unescaped from `''` doubling.
pub fn tokenize(allocator: Allocator, input: []const u8) LexError![]Token {
    var toks: std.ArrayList(Token) = .empty;
    errdefer toks.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        // Skip whitespace.
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        const start = i;
        switch (c) {
            '=' => {
                try toks.append(allocator, .{ .kind = .eq, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '<' => {
                if (i + 1 < input.len and input[i + 1] == '=') {
                    try toks.append(allocator, .{ .kind = .le, .text = input[i .. i + 2], .offset = start });
                    i += 2;
                } else if (i + 1 < input.len and input[i + 1] == '>') {
                    try toks.append(allocator, .{ .kind = .neq, .text = input[i .. i + 2], .offset = start });
                    i += 2;
                } else {
                    try toks.append(allocator, .{ .kind = .lt, .text = input[i .. i + 1], .offset = start });
                    i += 1;
                }
            },
            '>' => {
                if (i + 1 < input.len and input[i + 1] == '=') {
                    try toks.append(allocator, .{ .kind = .ge, .text = input[i .. i + 2], .offset = start });
                    i += 2;
                } else {
                    try toks.append(allocator, .{ .kind = .gt, .text = input[i .. i + 1], .offset = start });
                    i += 1;
                }
            },
            '!' => {
                if (i + 1 < input.len and input[i + 1] == '=') {
                    try toks.append(allocator, .{ .kind = .neq, .text = input[i .. i + 2], .offset = start });
                    i += 2;
                } else return LexError.InvalidCharacter;
            },
            '+' => {
                try toks.append(allocator, .{ .kind = .plus, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '-' => {
                try toks.append(allocator, .{ .kind = .minus, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '(' => {
                try toks.append(allocator, .{ .kind = .lparen, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            ')' => {
                try toks.append(allocator, .{ .kind = .rparen, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '{' => {
                try toks.append(allocator, .{ .kind = .lbrace, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '}' => {
                try toks.append(allocator, .{ .kind = .rbrace, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '[' => {
                try toks.append(allocator, .{ .kind = .lbracket, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            ']' => {
                try toks.append(allocator, .{ .kind = .rbracket, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            ',' => {
                try toks.append(allocator, .{ .kind = .comma, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '.' => {
                try toks.append(allocator, .{ .kind = .dot, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            ':' => {
                try toks.append(allocator, .{ .kind = .colon, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '*' => {
                try toks.append(allocator, .{ .kind = .star, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '?' => {
                try toks.append(allocator, .{ .kind = .question, .text = input[i .. i + 1], .offset = start });
                i += 1;
            },
            '\'' => {
                // String literal — supports SQL-style '' to escape a single quote.
                var end = i + 1;
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                while (end < input.len) {
                    if (input[end] == '\'') {
                        if (end + 1 < input.len and input[end + 1] == '\'') {
                            try buf.append(allocator, '\'');
                            end += 2;
                            continue;
                        }
                        break;
                    }
                    try buf.append(allocator, input[end]);
                    end += 1;
                }
                if (end >= input.len or input[end] != '\'') return LexError.UnterminatedString;
                const text = try buf.toOwnedSlice(allocator);
                try toks.append(allocator, .{ .kind = .string_literal, .text = text, .offset = start });
                i = end + 1;
            },
            '"' => {
                // Quoted identifier — case-sensitive, supports "" to escape ".
                var end = i + 1;
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                while (end < input.len) {
                    if (input[end] == '"') {
                        if (end + 1 < input.len and input[end + 1] == '"') {
                            try buf.append(allocator, '"');
                            end += 2;
                            continue;
                        }
                        break;
                    }
                    try buf.append(allocator, input[end]);
                    end += 1;
                }
                if (end >= input.len or input[end] != '"') return LexError.UnterminatedQuotedIdentifier;
                const text = try buf.toOwnedSlice(allocator);
                try toks.append(allocator, .{ .kind = .quoted_identifier, .text = text, .offset = start });
                i = end + 1;
            },
            '0'...'9' => {
                var end = i;
                while (end < input.len and isNumChar(input[end])) : (end += 1) {}
                try toks.append(allocator, .{ .kind = .number_literal, .text = input[start..end], .offset = start });
                i = end;
            },
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    var end = i;
                    while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) : (end += 1) {}
                    const word = input[start..end];
                    const lower = try toLowerOwned(allocator, word);
                    try toks.append(allocator, .{
                        .kind = classifyWord(lower),
                        .text = lower,
                        .offset = start,
                    });
                    i = end;
                } else return LexError.InvalidCharacter;
            },
        }
    }
    try toks.append(allocator, .{ .kind = .eof, .text = "", .offset = input.len });
    return toks.toOwnedSlice(allocator);
}

fn isNumChar(c: u8) bool {
    return std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-';
}

fn toLowerOwned(allocator: Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Map a case-folded word to its keyword TokenKind, or `.identifier`
/// if it's not a reserved PartiQL word.
fn classifyWord(lower: []const u8) TokenKind {
    const KW = struct { text: []const u8, kind: TokenKind };
    const kws = [_]KW{
        .{ .text = "select", .kind = .kw_select },
        .{ .text = "from", .kind = .kw_from },
        .{ .text = "where", .kind = .kw_where },
        .{ .text = "insert", .kind = .kw_insert },
        .{ .text = "into", .kind = .kw_into },
        .{ .text = "value", .kind = .kw_value },
        .{ .text = "values", .kind = .kw_values },
        .{ .text = "update", .kind = .kw_update },
        .{ .text = "set", .kind = .kw_set },
        .{ .text = "delete", .kind = .kw_delete },
        .{ .text = "returning", .kind = .kw_returning },
        .{ .text = "and", .kind = .kw_and },
        .{ .text = "or", .kind = .kw_or },
        .{ .text = "not", .kind = .kw_not },
        .{ .text = "between", .kind = .kw_between },
        .{ .text = "in", .kind = .kw_in },
        .{ .text = "is", .kind = .kw_is },
        .{ .text = "null", .kind = .kw_null },
        .{ .text = "true", .kind = .kw_true },
        .{ .text = "false", .kind = .kw_false },
        .{ .text = "all", .kind = .kw_all },
        .{ .text = "modified", .kind = .kw_modified },
        .{ .text = "old", .kind = .kw_old },
        .{ .text = "new", .kind = .kw_new },
    };
    for (kws) |kw| {
        if (std.mem.eql(u8, kw.text, lower)) return kw.kind;
    }
    return .identifier;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "tokenize: SELECT statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "SELECT * FROM \"users\" WHERE id = ?");
    try testing.expectEqual(TokenKind.kw_select, toks[0].kind);
    try testing.expectEqual(TokenKind.star, toks[1].kind);
    try testing.expectEqual(TokenKind.kw_from, toks[2].kind);
    try testing.expectEqual(TokenKind.quoted_identifier, toks[3].kind);
    try testing.expectEqualStrings("users", toks[3].text);
    try testing.expectEqual(TokenKind.kw_where, toks[4].kind);
    try testing.expectEqual(TokenKind.identifier, toks[5].kind);
    try testing.expectEqualStrings("id", toks[5].text);
    try testing.expectEqual(TokenKind.eq, toks[6].kind);
    try testing.expectEqual(TokenKind.question, toks[7].kind);
    try testing.expectEqual(TokenKind.eof, toks[8].kind);
}

test "tokenize: case-folds unquoted identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "SELECT Foo FROM Bar");
    try testing.expectEqualStrings("foo", toks[1].text);
    try testing.expectEqualStrings("bar", toks[3].text);
}

test "tokenize: preserves case in quoted identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "SELECT \"Foo\" FROM \"Bar\"");
    try testing.expectEqualStrings("Foo", toks[1].text);
    try testing.expectEqualStrings("Bar", toks[3].text);
}

test "tokenize: string literal with escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "'it''s'");
    try testing.expectEqual(TokenKind.string_literal, toks[0].kind);
    try testing.expectEqualStrings("it's", toks[0].text);
}

test "tokenize: operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "<= >= <> != = < >");
    try testing.expectEqual(TokenKind.le, toks[0].kind);
    try testing.expectEqual(TokenKind.ge, toks[1].kind);
    try testing.expectEqual(TokenKind.neq, toks[2].kind);
    try testing.expectEqual(TokenKind.neq, toks[3].kind);
    try testing.expectEqual(TokenKind.eq, toks[4].kind);
    try testing.expectEqual(TokenKind.lt, toks[5].kind);
    try testing.expectEqual(TokenKind.gt, toks[6].kind);
}

test "tokenize: UPDATE statement with ?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "UPDATE \"t\" SET v = v + ? WHERE id = ?");
    try testing.expectEqual(TokenKind.kw_update, toks[0].kind);
    try testing.expectEqual(TokenKind.quoted_identifier, toks[1].kind);
    try testing.expectEqual(TokenKind.kw_set, toks[2].kind);
}

test "tokenize: unterminated string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(LexError.UnterminatedString, tokenize(arena.allocator(), "'open"));
}

test "tokenize: unterminated quoted identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(LexError.UnterminatedQuotedIdentifier, tokenize(arena.allocator(), "\"open"));
}
