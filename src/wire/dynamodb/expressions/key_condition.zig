//! DynamoDB KeyConditionExpression parser.
//!
//! Grammar (Query-only, strict subset of ConditionExpression):
//!
//!   key_condition ::= pk_pred [ AND sk_pred ]
//!   pk_pred       ::= pk_name = operand
//!   sk_pred       ::= sk_name op operand
//!                  | sk_name BETWEEN operand AND operand
//!                  | begins_with(sk_name, operand)
//!   op            ::= = | < | <= | > | >=

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const condition_mod = @import("condition.zig");
const Operand = condition_mod.Operand;

pub const ParseError = error{ Malformed, OutOfMemory, InvalidToken };

pub const SortPredicate = union(enum) {
    eq: Operand,
    lt: Operand,
    le: Operand,
    gt: Operand,
    ge: Operand,
    between: struct { lo: Operand, hi: Operand },
    begins_with: Operand,
};

pub const KeyCondition = struct {
    pk_name: []const u8,
    pk_value: Operand,
    sk_name: ?[]const u8 = null,
    sk_predicate: ?SortPredicate = null,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    cond: KeyCondition,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

pub fn parse(
    allocator: Allocator,
    input: []const u8,
    expression_attribute_names: ?std.json.Value,
) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const toks = lexer.tokenize(a, input) catch return ParseError.Malformed;
    var p: Parser = .{ .toks = toks, .pos = 0, .arena = a, .names = expression_attribute_names };

    const pk_name = try p.parseName();
    _ = try p.expect(.eq);
    const pk_value = try p.parseOperand();

    var cond: KeyCondition = .{ .pk_name = pk_name, .pk_value = pk_value };

    if (p.accept(.kw_and)) |_| {
        const sk_name = try p.parseSortPart(&cond);
        _ = sk_name;
    }

    if (p.peek().kind != .eof) return ParseError.Malformed;
    return .{ .arena = arena, .cond = cond };
}

const Parser = struct {
    toks: []const Token,
    pos: usize,
    arena: Allocator,
    names: ?std.json.Value,

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

    fn parseName(self: *Parser) ParseError![]const u8 {
        const t = self.peek();
        switch (t.kind) {
            .identifier => {
                _ = self.advance();
                return t.text;
            },
            .name_placeholder => {
                _ = self.advance();
                return self.resolveName(t.text) catch return ParseError.Malformed;
            },
            else => return ParseError.Malformed,
        }
    }

    fn parseOperand(self: *Parser) ParseError!Operand {
        const t = self.peek();
        switch (t.kind) {
            .value_placeholder => {
                _ = self.advance();
                return .{ .value_ref = t.text };
            },
            .number => {
                _ = self.advance();
                return .{ .number_literal = t.text };
            },
            else => return ParseError.Malformed,
        }
    }

    fn parseSortPart(self: *Parser, cond: *KeyCondition) ParseError!void {
        // Function-call form: begins_with(sk, :p)
        if (self.peek().kind == .identifier) {
            const next_pos = self.pos + 1;
            if (next_pos < self.toks.len and self.toks[next_pos].kind == .lparen) {
                const fn_tok = self.advance();
                _ = try self.expect(.lparen);
                if (!asciiEqlIgnoreCase(fn_tok.text, "begins_with")) return ParseError.Malformed;
                const sk_name = try self.parseName();
                _ = try self.expect(.comma);
                const prefix = try self.parseOperand();
                _ = try self.expect(.rparen);
                cond.sk_name = sk_name;
                cond.sk_predicate = .{ .begins_with = prefix };
                return;
            }
        }
        // sk_name op operand | sk_name BETWEEN
        const sk_name = try self.parseName();
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

    fn resolveName(self: *Parser, placeholder: []const u8) ![]const u8 {
        const names = self.names orelse return placeholder;
        if (names != .object) return ParseError.Malformed;
        const v = names.object.get(placeholder) orelse return ParseError.Malformed;
        if (v != .string) return ParseError.Malformed;
        return v.string;
    }
};

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

const testing = std.testing;

test "parse: pk only" {
    var doc = try parse(testing.allocator, "pk = :v", null);
    defer doc.deinit();
    try testing.expectEqualStrings("pk", doc.cond.pk_name);
    try testing.expect(doc.cond.sk_name == null);
}

test "parse: pk AND sk =" {
    var doc = try parse(testing.allocator, "pk = :p AND sk = :s", null);
    defer doc.deinit();
    try testing.expectEqualStrings("pk", doc.cond.pk_name);
    try testing.expectEqualStrings("sk", doc.cond.sk_name.?);
    try testing.expect(doc.cond.sk_predicate.? == .eq);
}

test "parse: pk AND sk BETWEEN" {
    var doc = try parse(testing.allocator, "pk = :p AND sk BETWEEN :a AND :b", null);
    defer doc.deinit();
    try testing.expect(doc.cond.sk_predicate.? == .between);
}

test "parse: pk AND begins_with(sk, :p)" {
    var doc = try parse(testing.allocator, "pk = :p AND begins_with(sk, :px)", null);
    defer doc.deinit();
    try testing.expect(doc.cond.sk_predicate.? == .begins_with);
}
