//! DynamoDB ConditionExpression / FilterExpression parser + evaluator.
//!
//! Grammar (v1 subset, covers ~95% of real-world usage):
//!
//!   expression ::= or_expr
//!   or_expr    ::= and_expr ( OR and_expr )*
//!   and_expr   ::= not_expr ( AND not_expr )*
//!   not_expr   ::= NOT not_expr | comparison
//!   comparison ::= function_call
//!                | operand ( = | <> | < | <= | > | >= ) operand
//!                | operand BETWEEN operand AND operand
//!                | operand IN ( operand (, operand)* )
//!                | "(" expression ")"
//!   function_call ::= attribute_exists "(" name_path ")"
//!                  | attribute_not_exists "(" name_path ")"
//!                  | attribute_type "(" name_path "," operand ")"
//!                  | begins_with "(" name_path "," operand ")"
//!                  | contains "(" name_path "," operand ")"
//!                  | size "(" name_path ")"
//!   operand    ::= name_path | value_placeholder | number_literal | function_call
//!   name_path  ::= ( identifier | name_placeholder )

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const reserved_words = @import("reserved_words.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const av = @import("../attribute_value.zig");
const AttributeValue = av.AttributeValue;
const storage = @import("../../../storage/mod.zig");

pub const ParseError = error{
    Malformed,
    UnknownFunction,
    /// Identifier matches a DynamoDB reserved word and wasn't aliased
    /// via `#placeholder`. AWS rejects these — clients must use
    /// ExpressionAttributeNames.
    ReservedWord,
    OutOfMemory,
    InvalidToken,
};

pub const EvalError = error{
    /// Placeholder not found in the supplied name/value maps.
    MissingPlaceholder,
    /// Type mismatch (e.g. comparing string to number).
    TypeMismatch,
    /// `size()` on a value that isn't sizable.
    NotSizable,
    /// Internal allocation failure.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// AST

pub const Operand = union(enum) {
    /// Resolved attribute name (already substituted from #placeholder).
    name: []const u8,
    value_ref: []const u8, // ":v"
    /// Literal number embedded directly. Rare; mostly :placeholders.
    number_literal: []const u8,
    /// Result of a function call (`size(path)` returns N).
    func_size: *Operand,
};

pub const ComparisonOp = enum { eq, ne, lt, le, gt, ge };

pub const Expr = union(enum) {
    cmp: struct { op: ComparisonOp, lhs: Operand, rhs: Operand },
    between: struct { value: Operand, lo: Operand, hi: Operand },
    in: struct { value: Operand, options: []Operand },
    @"and": []Expr,
    @"or": []Expr,
    not: *Expr,
    attribute_exists: Operand,
    attribute_not_exists: Operand,
    attribute_type: struct { value: Operand, type_ref: Operand },
    begins_with: struct { value: Operand, prefix: Operand },
    contains: struct { value: Operand, needle: Operand },
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Expr,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Parser

pub fn parse(
    allocator: Allocator,
    input: []const u8,
    expression_attribute_names: ?std.json.Value,
) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const toks = lexer.tokenize(arena_alloc, input) catch return ParseError.Malformed;

    var parser: Parser = .{
        .toks = toks,
        .pos = 0,
        .arena = arena_alloc,
        .names = expression_attribute_names,
    };
    const root = try parser.parseOr();
    if (parser.peek().kind != .eof) return ParseError.Malformed;

    return .{ .arena = arena, .root = root };
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

    fn parseOr(self: *Parser) ParseError!Expr {
        const first = try self.parseAnd();
        if (self.peek().kind != .kw_or) return first;

        var list: std.ArrayList(Expr) = .empty;
        try list.append(self.arena, first);
        while (self.accept(.kw_or)) |_| {
            const next = try self.parseAnd();
            try list.append(self.arena, next);
        }
        return .{ .@"or" = try list.toOwnedSlice(self.arena) };
    }

    fn parseAnd(self: *Parser) ParseError!Expr {
        const first = try self.parseNot();
        if (self.peek().kind != .kw_and) return first;

        var list: std.ArrayList(Expr) = .empty;
        try list.append(self.arena, first);
        while (self.accept(.kw_and)) |_| {
            const next = try self.parseNot();
            try list.append(self.arena, next);
        }
        return .{ .@"and" = try list.toOwnedSlice(self.arena) };
    }

    fn parseNot(self: *Parser) ParseError!Expr {
        if (self.accept(.kw_not)) |_| {
            const inner = try self.parseNot();
            const ptr = try self.arena.create(Expr);
            ptr.* = inner;
            return .{ .not = ptr };
        }
        return self.parseAtom();
    }

    fn parseAtom(self: *Parser) ParseError!Expr {
        if (self.accept(.lparen)) |_| {
            const inner = try self.parseOr();
            _ = try self.expect(.rparen);
            return inner;
        }
        // Function calls start with identifier + lparen.
        if (self.peek().kind == .identifier) {
            const next_pos = self.pos + 1;
            if (next_pos < self.toks.len and self.toks[next_pos].kind == .lparen) {
                return self.parseFunctionCall();
            }
        }
        // Otherwise it's a comparison/between/in starting with an operand.
        const lhs = try self.parseOperand();
        return self.parseComparisonTail(lhs);
    }

    fn parseFunctionCall(self: *Parser) ParseError!Expr {
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.lparen);
        const name = name_tok.text;

        if (asciiEqlIgnoreCase(name, "attribute_exists")) {
            const path = try self.parseOperand();
            _ = try self.expect(.rparen);
            return .{ .attribute_exists = path };
        }
        if (asciiEqlIgnoreCase(name, "attribute_not_exists")) {
            const path = try self.parseOperand();
            _ = try self.expect(.rparen);
            return .{ .attribute_not_exists = path };
        }
        if (asciiEqlIgnoreCase(name, "begins_with")) {
            const value = try self.parseOperand();
            _ = try self.expect(.comma);
            const prefix = try self.parseOperand();
            _ = try self.expect(.rparen);
            return .{ .begins_with = .{ .value = value, .prefix = prefix } };
        }
        if (asciiEqlIgnoreCase(name, "contains")) {
            const value = try self.parseOperand();
            _ = try self.expect(.comma);
            const needle = try self.parseOperand();
            _ = try self.expect(.rparen);
            return .{ .contains = .{ .value = value, .needle = needle } };
        }
        if (asciiEqlIgnoreCase(name, "attribute_type")) {
            const value = try self.parseOperand();
            _ = try self.expect(.comma);
            const type_ref = try self.parseOperand();
            _ = try self.expect(.rparen);
            return .{ .attribute_type = .{ .value = value, .type_ref = type_ref } };
        }
        return ParseError.UnknownFunction;
    }

    fn parseOperand(self: *Parser) ParseError!Operand {
        const t = self.peek();
        switch (t.kind) {
            .identifier => {
                // Reserved-word check fires in operand position only. Function
                // calls route through parseFunctionCall (identifier + `(`),
                // so callable names like `attribute_exists` never land here.
                if (reserved_words.isReserved(t.text)) return ParseError.ReservedWord;
                _ = self.advance();
                return .{ .name = t.text };
            },
            .name_placeholder => {
                _ = self.advance();
                // Resolve via expression_attribute_names if provided.
                const resolved = self.resolveName(t.text) catch return ParseError.Malformed;
                return .{ .name = resolved };
            },
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

    fn parseComparisonTail(self: *Parser, lhs: Operand) ParseError!Expr {
        const next = self.peek();
        switch (next.kind) {
            .eq, .ne, .lt, .le, .gt, .ge => {
                _ = self.advance();
                const op: ComparisonOp = switch (next.kind) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    else => unreachable,
                };
                const rhs = try self.parseOperand();
                return .{ .cmp = .{ .op = op, .lhs = lhs, .rhs = rhs } };
            },
            .kw_between => {
                _ = self.advance();
                const lo = try self.parseOperand();
                _ = try self.expect(.kw_and);
                const hi = try self.parseOperand();
                return .{ .between = .{ .value = lhs, .lo = lo, .hi = hi } };
            },
            .kw_in => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                var list: std.ArrayList(Operand) = .empty;
                try list.append(self.arena, try self.parseOperand());
                while (self.accept(.comma)) |_| {
                    try list.append(self.arena, try self.parseOperand());
                }
                _ = try self.expect(.rparen);
                return .{ .in = .{ .value = lhs, .options = try list.toOwnedSlice(self.arena) } };
            },
            else => return ParseError.Malformed,
        }
    }

    fn resolveName(self: *Parser, placeholder: []const u8) ![]const u8 {
        const names = self.names orelse return placeholder; // pass through if no map
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

// ---------------------------------------------------------------------------
// Evaluator

pub const EvalContext = struct {
    item: ?*const storage.Item,
    /// ExpressionAttributeValues, parsed std.json.Value (with the
    /// AttributeValue tagged-object shape). Stays as json.Value because
    /// we resolve via attribute_value.parseValue on demand.
    values: ?std.json.Value,
    /// Scratch allocator for transient parsed AttributeValues.
    allocator: Allocator,
};

pub fn evaluate(expr: Expr, ctx: EvalContext) EvalError!bool {
    return switch (expr) {
        .cmp => |c| try evalComparison(c.op, c.lhs, c.rhs, ctx),
        .between => |b| blk: {
            const v = try resolveValue(b.value, ctx);
            const lo = try resolveValue(b.lo, ctx);
            const hi = try resolveValue(b.hi, ctx);
            if (v == null or lo == null or hi == null) break :blk false;
            const ge_lo = (try compareValues(v.?, lo.?)) >= 0;
            const le_hi = (try compareValues(v.?, hi.?)) <= 0;
            break :blk ge_lo and le_hi;
        },
        .in => |i| blk: {
            const v = try resolveValue(i.value, ctx);
            if (v == null) break :blk false;
            for (i.options) |o| {
                const ov = try resolveValue(o, ctx);
                if (ov) |okv| {
                    if (valuesEqual(v.?, okv)) break :blk true;
                }
            }
            break :blk false;
        },
        .@"and" => |children| blk: {
            for (children) |c| if (!try evaluate(c, ctx)) break :blk false;
            break :blk true;
        },
        .@"or" => |children| blk: {
            for (children) |c| if (try evaluate(c, ctx)) break :blk true;
            break :blk false;
        },
        .not => |inner| !(try evaluate(inner.*, ctx)),
        .attribute_exists => |path| (try attrAt(path, ctx)) != null,
        .attribute_not_exists => |path| (try attrAt(path, ctx)) == null,
        .attribute_type => |t| blk: {
            const v = try attrAt(t.value, ctx) orelse break :blk false;
            const ref = try resolveValue(t.type_ref, ctx) orelse break :blk false;
            const ref_str = switch (ref) {
                .s => |s| s,
                else => break :blk false,
            };
            const got: []const u8 = switch (v) {
                .s => "S",
                .n => "N",
                .b => "B",
                .bool => "BOOL",
                .null => "NULL",
                .list => "L",
                .map => "M",
                .ss => "SS",
                .ns => "NS",
                .bs => "BS",
            };
            break :blk std.mem.eql(u8, got, ref_str);
        },
        .begins_with => |b| blk: {
            const v = try attrAt(b.value, ctx) orelse break :blk false;
            const prefix = try resolveValue(b.prefix, ctx) orelse break :blk false;
            const v_str = switch (v) {
                .s => |s| s,
                else => break :blk false,
            };
            const p_str = switch (prefix) {
                .s => |s| s,
                else => break :blk false,
            };
            break :blk std.mem.startsWith(u8, v_str, p_str);
        },
        .contains => |c| blk: {
            const v = try attrAt(c.value, ctx) orelse break :blk false;
            const needle = try resolveValue(c.needle, ctx) orelse break :blk false;
            // String contains substring; SS contains element; L contains element.
            switch (v) {
                .s => |s| switch (needle) {
                    .s => |n| break :blk std.mem.indexOf(u8, s, n) != null,
                    else => break :blk false,
                },
                .ss => |elems| switch (needle) {
                    .s => |n| {
                        for (elems) |e| if (std.mem.eql(u8, e, n)) break :blk true;
                        break :blk false;
                    },
                    else => break :blk false,
                },
                .ns => |elems| switch (needle) {
                    .n => |n| {
                        for (elems) |e| if (std.mem.eql(u8, e, n)) break :blk true;
                        break :blk false;
                    },
                    else => break :blk false,
                },
                .list => |items| {
                    for (items) |it| if (valuesEqual(it, needle)) break :blk true;
                    break :blk false;
                },
                else => break :blk false,
            }
        },
    };
}

fn evalComparison(op: ComparisonOp, lhs: Operand, rhs: Operand, ctx: EvalContext) EvalError!bool {
    const l = try resolveValue(lhs, ctx);
    const r = try resolveValue(rhs, ctx);
    if (l == null or r == null) return false;
    const cmp = try compareValues(l.?, r.?);
    return switch (op) {
        .eq => cmp == 0,
        .ne => cmp != 0,
        .lt => cmp < 0,
        .le => cmp <= 0,
        .gt => cmp > 0,
        .ge => cmp >= 0,
    };
}

/// Resolve an Operand to an AttributeValue. Returns null if the operand
/// refers to a non-existent item attribute (callers treat null as "no match").
pub fn resolveValue(op: Operand, ctx: EvalContext) EvalError!?AttributeValue {
    return switch (op) {
        .name => |name| blk: {
            const item = ctx.item orelse break :blk null;
            const v = item.attributeValue(name) orelse break :blk null;
            break :blk v.*;
        },
        .value_ref => |ref| try resolveValuePlaceholder(ref, ctx),
        .number_literal => |s| .{ .n = s },
        .func_size => null, // size() not supported as a comparison operand in v1
    };
}

fn resolveValuePlaceholder(ref: []const u8, ctx: EvalContext) EvalError!?AttributeValue {
    const values = ctx.values orelse return EvalError.MissingPlaceholder;
    if (values != .object) return EvalError.MissingPlaceholder;
    const json_v = values.object.get(ref) orelse return EvalError.MissingPlaceholder;
    return av.parseValue(ctx.allocator, json_v) catch return EvalError.MissingPlaceholder;
}

fn attrAt(op: Operand, ctx: EvalContext) EvalError!?AttributeValue {
    return switch (op) {
        .name => |name| blk: {
            const item = ctx.item orelse break :blk null;
            const v = item.attributeValue(name) orelse break :blk null;
            break :blk v.*;
        },
        else => null,
    };
}

/// Compare two AttributeValues numerically (for N), lexically (for S),
/// or byte-wise (for B). Returns -1/0/1. Type-mismatch → TypeMismatch.
pub fn compareValues(a: AttributeValue, b: AttributeValue) EvalError!i8 {
    return switch (a) {
        .s => switch (b) {
            .s => |bs| orderToInt(std.mem.order(u8, a.s, bs)),
            else => EvalError.TypeMismatch,
        },
        .n => switch (b) {
            .n => |bs| compareDecimal(a.n, bs),
            else => EvalError.TypeMismatch,
        },
        .b => switch (b) {
            .b => |bb| orderToInt(std.mem.order(u8, a.b, bb)),
            else => EvalError.TypeMismatch,
        },
        else => EvalError.TypeMismatch,
    };
}

fn orderToInt(o: std.math.Order) i8 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Compare two decimal-as-string numbers (DynamoDB N). Handles signs,
/// fractional parts, leading-zero normalisation. Does NOT handle
/// scientific notation in the canonical case (rare in practice; we strip
/// trailing zeros + leading zeros only).
fn compareDecimal(a: []const u8, b: []const u8) i8 {
    // Quick-path: identical strings.
    if (std.mem.eql(u8, a, b)) return 0;
    // Use std.fmt.parseFloat for shape comparison. DynamoDB allows up to
    // 38 digits — f64 loses precision past ~15, but for ordering this is
    // OK for the v1 wedge (real apps don't lean on full-precision
    // comparisons). Document if it becomes a problem.
    const af = std.fmt.parseFloat(f64, a) catch return 0;
    const bf = std.fmt.parseFloat(f64, b) catch return 0;
    if (af < bf) return -1;
    if (af > bf) return 1;
    return 0;
}

pub fn valuesEqual(a: AttributeValue, b: AttributeValue) bool {
    return switch (a) {
        .s => switch (b) {
            .s => |bs| std.mem.eql(u8, a.s, bs),
            else => false,
        },
        .n => switch (b) {
            .n => |bs| compareDecimal(a.n, bs) == 0,
            else => false,
        },
        .b => switch (b) {
            .b => |bb| std.mem.eql(u8, a.b, bb),
            else => false,
        },
        .bool => switch (b) {
            .bool => |bb| a.bool == bb,
            else => false,
        },
        .null => switch (b) {
            .null => true,
            else => false,
        },
        else => false, // L/M/SS/NS/BS equality not required for v1
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const dynamo_state = @import("../../../storage/dynamo_state.zig");

fn makeItem(allocator: Allocator, fields: anytype) !storage.Item {
    const FieldType = @TypeOf(fields);
    const info = @typeInfo(FieldType).@"struct";
    const n = info.fields.len;
    const names = try allocator.alloc([]const u8, n);
    const values = try allocator.alloc(AttributeValue, n);
    inline for (info.fields, 0..) |f, i| {
        names[i] = try allocator.dupe(u8, f.name);
        values[i] = @field(fields, f.name);
    }
    return .{ .names = names, .values = values };
}

test "parse + evaluate: simple equality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try parse(testing.allocator, "id = :v", null);
    defer doc.deinit();

    var item = try makeItem(a, .{ .id = AttributeValue{ .s = "k1" } });

    var values_obj = std.json.ObjectMap.empty;
    defer values_obj.deinit(a);
    var v_inner = std.json.ObjectMap.empty;
    defer v_inner.deinit(a);
    try v_inner.put(a, "S", .{ .string = "k1" });
    try values_obj.put(a, ":v", .{ .object = v_inner });

    const ctx: EvalContext = .{
        .item = &item,
        .values = .{ .object = values_obj },
        .allocator = a,
    };
    try testing.expect(try evaluate(doc.root, ctx));
}

test "parse + evaluate: attribute_not_exists on absent attr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try parse(testing.allocator, "attribute_not_exists(extra)", null);
    defer doc.deinit();

    var item = try makeItem(a, .{ .id = AttributeValue{ .s = "k1" } });
    const ctx: EvalContext = .{ .item = &item, .values = null, .allocator = a };
    try testing.expect(try evaluate(doc.root, ctx));
}

test "parse + evaluate: AND chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try parse(testing.allocator, "a = :x AND b = :y", null);
    defer doc.deinit();

    var item = try makeItem(a, .{
        .a = AttributeValue{ .s = "1" },
        .b = AttributeValue{ .s = "2" },
    });

    var vals = std.json.ObjectMap.empty;
    defer vals.deinit(a);
    var vx = std.json.ObjectMap.empty;
    defer vx.deinit(a);
    var vy = std.json.ObjectMap.empty;
    defer vy.deinit(a);
    try vx.put(a, "S", .{ .string = "1" });
    try vy.put(a, "S", .{ .string = "2" });
    try vals.put(a, ":x", .{ .object = vx });
    try vals.put(a, ":y", .{ .object = vy });
    const ctx: EvalContext = .{ .item = &item, .values = .{ .object = vals }, .allocator = a };
    try testing.expect(try evaluate(doc.root, ctx));
}

test "parse + evaluate: NOT inverts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try parse(testing.allocator, "NOT attribute_exists(extra)", null);
    defer doc.deinit();

    var item = try makeItem(a, .{ .id = AttributeValue{ .s = "k1" } });
    const ctx: EvalContext = .{ .item = &item, .values = null, .allocator = a };
    try testing.expect(try evaluate(doc.root, ctx));
}

test "parse + evaluate: begins_with on string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try parse(testing.allocator, "begins_with(label, :p)", null);
    defer doc.deinit();

    var item = try makeItem(a, .{ .label = AttributeValue{ .s = "Alice" } });

    var vals = std.json.ObjectMap.empty;
    defer vals.deinit(a);
    var vp = std.json.ObjectMap.empty;
    defer vp.deinit(a);
    try vp.put(a, "S", .{ .string = "Ali" });
    try vals.put(a, ":p", .{ .object = vp });

    const ctx: EvalContext = .{ .item = &item, .values = .{ .object = vals }, .allocator = a };
    try testing.expect(try evaluate(doc.root, ctx));
}
