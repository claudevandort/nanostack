//! PartiQL parser for DynamoDB (v0.2.4).
//!
//! Recursive-descent. Consumes the token stream from `lexer.zig`,
//! produces a `Statement` AST defined in `ast.zig`. Phase 1 covers the
//! SELECT grammar; later phases extend with INSERT / UPDATE / DELETE.
//!
//! Grammar (Phase 1):
//!
//!   select_stmt ::= SELECT (* | col_list) FROM table_ref [WHERE key_cond]
//!   col_list    ::= identifier (',' identifier)*
//!   table_ref   ::= quoted_or_unquoted ('.' quoted_or_unquoted)?
//!   key_cond    ::= identifier '=' operand (AND sk_pred)?
//!   sk_pred     ::= identifier op operand
//!                 | identifier BETWEEN operand AND operand
//!                 | 'begins_with' '(' identifier ',' operand ')'
//!   op          ::= = | < | <= | > | >=
//!   operand     ::= '?' | number | string | true | false | NULL
//!
//! The parser tracks `?` occurrences in encounter order so the handler
//! can map `Parameters[N]` to each placeholder by index.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

pub const ParseError = error{
    Malformed,
    UnsupportedStatement,
    NumberLiteralInvalid,
    OutOfMemory,
    InvalidToken,
};

pub fn parse(allocator: Allocator, input: []const u8) ParseError!ast.ParsedStatement {
    const toks = lexer.tokenize(allocator, input) catch return ParseError.InvalidToken;
    var p: Parser = .{ .toks = toks, .pos = 0, .allocator = allocator, .param_index = 0 };

    const first = p.peek().kind;
    const stmt: ast.Statement = switch (first) {
        .kw_select => .{ .select = try p.parseSelect() },
        else => return ParseError.UnsupportedStatement,
    };

    if (p.peek().kind != .eof) return ParseError.Malformed;
    return .{ .statement = stmt, .placeholder_count = p.param_index };
}

const Parser = struct {
    toks: []const Token,
    pos: usize,
    allocator: Allocator,
    param_index: u32,

    fn peek(self: *Parser) Token {
        return self.toks[self.pos];
    }

    fn advance(self: *Parser) Token {
        const t = self.toks[self.pos];
        if (self.pos < self.toks.len - 1) self.pos += 1;
        return t;
    }

    fn accept(self: *Parser, kind: TokenKind) ?Token {
        if (self.peek().kind == kind) return self.advance();
        return null;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (self.peek().kind == kind) return self.advance();
        return ParseError.Malformed;
    }

    fn parseSelect(self: *Parser) ParseError!ast.Select {
        _ = try self.expect(.kw_select);

        // Columns: '*' or comma-separated identifiers.
        var columns: std.ArrayList(ast.ColumnRef) = .empty;
        errdefer columns.deinit(self.allocator);
        if (self.accept(.star)) |_| {
            try columns.append(self.allocator, .star);
        } else {
            try columns.append(self.allocator, .{ .name = try self.parseIdent() });
            while (self.accept(.comma)) |_| {
                try columns.append(self.allocator, .{ .name = try self.parseIdent() });
            }
        }

        _ = try self.expect(.kw_from);

        // Table reference: name or name.index_name.
        const table_name = try self.parseIdent();
        var index_name: ?[]const u8 = null;
        if (self.accept(.dot)) |_| {
            index_name = try self.parseIdent();
        }

        // Optional WHERE.
        var where_clause: ?ast.KeyCondition = null;
        if (self.accept(.kw_where)) |_| {
            where_clause = try self.parseKeyCondition();
        }

        return .{
            .table_name = table_name,
            .index_name = index_name,
            .columns = try columns.toOwnedSlice(self.allocator),
            .where_clause = where_clause,
        };
    }

    fn parseIdent(self: *Parser) ParseError![]const u8 {
        const t = self.peek();
        return switch (t.kind) {
            .identifier, .quoted_identifier => blk: {
                _ = self.advance();
                break :blk t.text;
            },
            else => ParseError.Malformed,
        };
    }

    fn parseKeyCondition(self: *Parser) ParseError!ast.KeyCondition {
        const pk_name = try self.parseIdent();
        _ = try self.expect(.eq);
        const pk_value = try self.parseOperand();

        var cond: ast.KeyCondition = .{ .pk_name = pk_name, .pk_value = pk_value };

        if (self.accept(.kw_and)) |_| {
            try self.parseSortPredicate(&cond);
        }
        return cond;
    }

    fn parseSortPredicate(self: *Parser, cond: *ast.KeyCondition) ParseError!void {
        // begins_with(name, prefix) — function call form.
        if (self.peek().kind == .identifier) {
            const next = self.pos + 1;
            if (next < self.toks.len and self.toks[next].kind == .lparen) {
                const fn_tok = self.advance();
                _ = try self.expect(.lparen);
                if (!std.mem.eql(u8, fn_tok.text, "begins_with")) return ParseError.Malformed;
                const sk_name = try self.parseIdent();
                _ = try self.expect(.comma);
                const prefix = try self.parseOperand();
                _ = try self.expect(.rparen);
                cond.sk_name = sk_name;
                cond.sk_predicate = .{ .begins_with = prefix };
                return;
            }
        }

        const sk_name = try self.parseIdent();
        cond.sk_name = sk_name;
        const op = self.advance();
        switch (op.kind) {
            .eq => cond.sk_predicate = .{ .eq = try self.parseOperand() },
            .lt => cond.sk_predicate = .{ .lt = try self.parseOperand() },
            .le => cond.sk_predicate = .{ .le = try self.parseOperand() },
            .gt => cond.sk_predicate = .{ .gt = try self.parseOperand() },
            .ge => cond.sk_predicate = .{ .ge = try self.parseOperand() },
            .kw_between => {
                const lo = try self.parseOperand();
                _ = try self.expect(.kw_and);
                const hi = try self.parseOperand();
                cond.sk_predicate = .{ .between = .{ .lo = lo, .hi = hi } };
            },
            else => return ParseError.Malformed,
        }
    }

    fn parseOperand(self: *Parser) ParseError!ast.Operand {
        const t = self.peek();
        return switch (t.kind) {
            .question => blk: {
                _ = self.advance();
                const idx = self.param_index;
                self.param_index += 1;
                break :blk .{ .param_index = idx };
            },
            .number_literal => blk: {
                _ = self.advance();
                if (!isValidDecimal(t.text)) return ParseError.NumberLiteralInvalid;
                break :blk .{ .literal = .{ .n = t.text } };
            },
            .string_literal => blk: {
                _ = self.advance();
                break :blk .{ .literal = .{ .s = t.text } };
            },
            .kw_true => blk: {
                _ = self.advance();
                break :blk .{ .literal = .{ .bool = true } };
            },
            .kw_false => blk: {
                _ = self.advance();
                break :blk .{ .literal = .{ .bool = false } };
            },
            .kw_null => blk: {
                _ = self.advance();
                break :blk .{ .literal = .null };
            },
            else => ParseError.Malformed,
        };
    }
};

fn isValidDecimal(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-' or s[i] == '+') i += 1;
    var saw_digit = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) saw_digit = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) saw_digit = true;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var saw_exp = false;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) saw_exp = true;
        if (!saw_exp) return false;
    }
    return saw_digit and i == s.len;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: SELECT * FROM table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT * FROM \"users\"");
    try testing.expectEqual(@as(u32, 0), got.placeholder_count);
    const sel = got.statement.select;
    try testing.expectEqualStrings("users", sel.table_name);
    try testing.expect(sel.index_name == null);
    try testing.expect(sel.columns[0] == .star);
    try testing.expect(sel.where_clause == null);
}

test "parse: SELECT with projection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT id, name FROM t");
    const sel = got.statement.select;
    try testing.expectEqual(@as(usize, 2), sel.columns.len);
    try testing.expectEqualStrings("id", sel.columns[0].name);
    try testing.expectEqualStrings("name", sel.columns[1].name);
}

test "parse: SELECT FROM table.index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT * FROM \"t\".\"gsi1\"");
    const sel = got.statement.select;
    try testing.expectEqualStrings("t", sel.table_name);
    try testing.expectEqualStrings("gsi1", sel.index_name.?);
}

test "parse: SELECT WHERE pk = ?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT * FROM t WHERE id = ?");
    try testing.expectEqual(@as(u32, 1), got.placeholder_count);
    const sel = got.statement.select;
    const w = sel.where_clause.?;
    try testing.expectEqualStrings("id", w.pk_name);
    try testing.expectEqual(@as(u32, 0), w.pk_value.param_index);
    try testing.expect(w.sk_name == null);
}

test "parse: SELECT WHERE pk = ? AND sk = ?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT * FROM t WHERE pk = ? AND sk = ?");
    try testing.expectEqual(@as(u32, 2), got.placeholder_count);
    const w = got.statement.select.where_clause.?;
    try testing.expectEqualStrings("pk", w.pk_name);
    try testing.expectEqualStrings("sk", w.sk_name.?);
    try testing.expect(w.sk_predicate.? == .eq);
}

test "parse: SELECT WHERE pk = ? AND begins_with(sk, ?)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT * FROM t WHERE pk = ? AND begins_with(sk, ?)");
    try testing.expectEqual(@as(u32, 2), got.placeholder_count);
    const w = got.statement.select.where_clause.?;
    try testing.expect(w.sk_predicate.? == .begins_with);
}

test "parse: SELECT WHERE pk = ? AND sk BETWEEN ? AND ?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT * FROM t WHERE pk = ? AND sk BETWEEN ? AND ?");
    try testing.expectEqual(@as(u32, 3), got.placeholder_count);
    const w = got.statement.select.where_clause.?;
    try testing.expect(w.sk_predicate.? == .between);
}

test "parse: SELECT WHERE pk = 'literal'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), "SELECT * FROM t WHERE id = 'abc'");
    const w = got.statement.select.where_clause.?;
    try testing.expect(w.pk_value == .literal);
    try testing.expectEqualStrings("abc", w.pk_value.literal.s);
}

test "parse: syntax error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ParseError.Malformed, parse(arena.allocator(), "SELECT FROM t"));
    try testing.expectError(ParseError.UnsupportedStatement, parse(arena.allocator(), "DROP TABLE t"));
}
