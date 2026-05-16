//! Shared lexer for DynamoDB ConditionExpression / UpdateExpression /
//! KeyConditionExpression / FilterExpression.
//!
//! Tokens: identifier, name-placeholder (#x), value-placeholder (:v),
//! number literal (used inside between/in args), string keywords
//! (AND/OR/NOT/BETWEEN/IN/SET/REMOVE/ADD/DELETE), punctuation
//! (= <> < <= > >= ( ) , . +  -), function-call tokens for the
//! recognised built-ins.
//!
//! The recursive-descent parsers consume these.

const std = @import("std");

pub const TokenKind = enum {
    // Identifiers + placeholders
    identifier,
    name_placeholder, // "#foo"
    value_placeholder, // ":v"
    // Literals (rare — most values arrive via :placeholder)
    number, // used in raw numeric paths
    // Punctuation
    lparen,
    rparen,
    comma,
    dot,
    plus,
    minus,
    // Comparison operators
    eq, // =
    ne, // <>
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
    // Logical
    kw_and,
    kw_or,
    kw_not,
    kw_between,
    kw_in,
    // UpdateExpression actions
    kw_set,
    kw_remove,
    kw_add,
    kw_delete,
    // End-of-input
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8, // borrowed slice into the original input
};

pub const LexError = error{InvalidToken};

const Lexer = struct {
    input: []const u8,
    pos: usize = 0,

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        const c = self.input[self.pos];
        self.pos += 1;
        return c;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') self.pos += 1 else return;
        }
    }
};

pub fn tokenize(allocator: std.mem.Allocator, input: []const u8) ![]Token {
    var lex: Lexer = .{ .input = input };
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        lex.skipWhitespace();
        const start = lex.pos;
        const c = lex.peek() orelse break;

        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (lex.peek()) |cc| {
                if (std.ascii.isAlphanumeric(cc) or cc == '_') {
                    lex.pos += 1;
                } else break;
            }
            const text = lex.input[start..lex.pos];
            try out.append(allocator, .{ .kind = classifyIdent(text), .text = text });
            continue;
        }

        if (c == '#') {
            lex.pos += 1;
            while (lex.peek()) |cc| {
                if (std.ascii.isAlphanumeric(cc) or cc == '_') {
                    lex.pos += 1;
                } else break;
            }
            try out.append(allocator, .{ .kind = .name_placeholder, .text = lex.input[start..lex.pos] });
            continue;
        }

        if (c == ':') {
            lex.pos += 1;
            while (lex.peek()) |cc| {
                if (std.ascii.isAlphanumeric(cc) or cc == '_') {
                    lex.pos += 1;
                } else break;
            }
            try out.append(allocator, .{ .kind = .value_placeholder, .text = lex.input[start..lex.pos] });
            continue;
        }

        if (std.ascii.isDigit(c)) {
            while (lex.peek()) |cc| {
                if (std.ascii.isDigit(cc) or cc == '.' or cc == 'e' or cc == 'E' or cc == '+' or cc == '-') {
                    lex.pos += 1;
                } else break;
            }
            try out.append(allocator, .{ .kind = .number, .text = lex.input[start..lex.pos] });
            continue;
        }

        // Multi-char operators first.
        if (c == '<') {
            lex.pos += 1;
            if (lex.peek() == @as(?u8, '=')) {
                lex.pos += 1;
                try out.append(allocator, .{ .kind = .le, .text = lex.input[start..lex.pos] });
            } else if (lex.peek() == @as(?u8, '>')) {
                lex.pos += 1;
                try out.append(allocator, .{ .kind = .ne, .text = lex.input[start..lex.pos] });
            } else {
                try out.append(allocator, .{ .kind = .lt, .text = lex.input[start..lex.pos] });
            }
            continue;
        }
        if (c == '>') {
            lex.pos += 1;
            if (lex.peek() == @as(?u8, '=')) {
                lex.pos += 1;
                try out.append(allocator, .{ .kind = .ge, .text = lex.input[start..lex.pos] });
            } else {
                try out.append(allocator, .{ .kind = .gt, .text = lex.input[start..lex.pos] });
            }
            continue;
        }

        const single: TokenKind = switch (c) {
            '=' => .eq,
            '(' => .lparen,
            ')' => .rparen,
            ',' => .comma,
            '.' => .dot,
            '+' => .plus,
            '-' => .minus,
            else => return LexError.InvalidToken,
        };
        lex.pos += 1;
        try out.append(allocator, .{ .kind = single, .text = lex.input[start..lex.pos] });
    }

    try out.append(allocator, .{ .kind = .eof, .text = "" });
    return out.toOwnedSlice(allocator);
}

fn classifyIdent(text: []const u8) TokenKind {
    if (asciiEqlIgnoreCase(text, "and")) return .kw_and;
    if (asciiEqlIgnoreCase(text, "or")) return .kw_or;
    if (asciiEqlIgnoreCase(text, "not")) return .kw_not;
    if (asciiEqlIgnoreCase(text, "between")) return .kw_between;
    if (asciiEqlIgnoreCase(text, "in")) return .kw_in;
    if (asciiEqlIgnoreCase(text, "set")) return .kw_set;
    if (asciiEqlIgnoreCase(text, "remove")) return .kw_remove;
    if (asciiEqlIgnoreCase(text, "add")) return .kw_add;
    if (asciiEqlIgnoreCase(text, "delete")) return .kw_delete;
    return .identifier;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

const testing = std.testing;

test "tokenize: simple comparison" {
    const toks = try tokenize(testing.allocator, "#a = :v");
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 4), toks.len); // #a, =, :v, eof
    try testing.expectEqual(TokenKind.name_placeholder, toks[0].kind);
    try testing.expectEqual(TokenKind.eq, toks[1].kind);
    try testing.expectEqual(TokenKind.value_placeholder, toks[2].kind);
    try testing.expectEqual(TokenKind.eof, toks[3].kind);
}

test "tokenize: keywords case-insensitive" {
    const toks = try tokenize(testing.allocator, "AND and AnD between BETWEEN");
    defer testing.allocator.free(toks);
    try testing.expectEqual(TokenKind.kw_and, toks[0].kind);
    try testing.expectEqual(TokenKind.kw_and, toks[1].kind);
    try testing.expectEqual(TokenKind.kw_and, toks[2].kind);
    try testing.expectEqual(TokenKind.kw_between, toks[3].kind);
    try testing.expectEqual(TokenKind.kw_between, toks[4].kind);
}

test "tokenize: comparison operators" {
    const toks = try tokenize(testing.allocator, "= <> < <= > >=");
    defer testing.allocator.free(toks);
    try testing.expectEqual(TokenKind.eq, toks[0].kind);
    try testing.expectEqual(TokenKind.ne, toks[1].kind);
    try testing.expectEqual(TokenKind.lt, toks[2].kind);
    try testing.expectEqual(TokenKind.le, toks[3].kind);
    try testing.expectEqual(TokenKind.gt, toks[4].kind);
    try testing.expectEqual(TokenKind.ge, toks[5].kind);
}
