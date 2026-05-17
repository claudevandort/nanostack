//! DynamoDB UpdateExpression parser + applier.
//!
//! Grammar (v1 subset — covers ~95% of real usage):
//!
//!   expression ::= action_section+
//!   action_section ::= SET set_action ( , set_action )*
//!                    | REMOVE name_path ( , name_path )*
//!                    | ADD name_path operand ( , name_path operand )*
//!                    | DELETE name_path operand ( , name_path operand )*
//!
//!   set_action ::= name_path = set_value
//!   set_value  ::= operand
//!                | operand "+" operand
//!                | operand "-" operand
//!                | "if_not_exists" "(" name_path "," operand ")"
//!                | "list_append" "(" operand "," operand ")"
//!
//!   operand    ::= name_path | value_placeholder | number_literal
//!   name_path  ::= identifier | name_placeholder
//!
//! Applier mutates a clone of the input item. Caller supplies
//! ExpressionAttributeNames / ExpressionAttributeValues maps.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const reserved_words = @import("reserved_words.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const condition_mod = @import("condition.zig");
const Operand = condition_mod.Operand;
const av = @import("../attribute_value.zig");
const AttributeValue = av.AttributeValue;
const storage = @import("../../../storage/mod.zig");

pub const ParseError = error{
    Malformed,
    UnknownFunction,
    /// Identifier matches a DynamoDB reserved word and wasn't aliased
    /// via `#placeholder`.
    ReservedWord,
    OutOfMemory,
    InvalidToken,
};

pub const ApplyError = error{
    MissingPlaceholder,
    TypeMismatch,
    InvalidNumber,
    NotASet,
    OutOfMemory,
};

pub const SetOperator = enum { add, subtract };

pub const SetExpr = union(enum) {
    operand: Operand,
    arith: struct { lhs: Operand, op: SetOperator, rhs: Operand },
    if_not_exists: struct { path: Operand, fallback: Operand },
    list_append: struct { lhs: Operand, rhs: Operand },
};

pub const Action = union(enum) {
    set: struct { path: Operand, value: SetExpr },
    remove: Operand,
    add: struct { path: Operand, value: Operand },
    delete: struct { path: Operand, value: Operand },
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    actions: []Action,

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
    const a = arena.allocator();

    const toks = lexer.tokenize(a, input) catch return ParseError.Malformed;
    var p: Parser = .{ .toks = toks, .pos = 0, .arena = a, .names = expression_attribute_names };

    var actions: std.ArrayList(Action) = .empty;
    while (p.peek().kind != .eof) {
        const kind = p.peek().kind;
        switch (kind) {
            .kw_set => {
                _ = p.advance();
                while (true) {
                    try actions.append(a, try p.parseSetAction());
                    if (p.accept(.comma) == null) break;
                }
            },
            .kw_remove => {
                _ = p.advance();
                while (true) {
                    const path = try p.parseOperand();
                    try actions.append(a, .{ .remove = path });
                    if (p.accept(.comma) == null) break;
                }
            },
            .kw_add => {
                _ = p.advance();
                while (true) {
                    const path = try p.parseOperand();
                    const val = try p.parseOperand();
                    try actions.append(a, .{ .add = .{ .path = path, .value = val } });
                    if (p.accept(.comma) == null) break;
                }
            },
            .kw_delete => {
                _ = p.advance();
                while (true) {
                    const path = try p.parseOperand();
                    const val = try p.parseOperand();
                    try actions.append(a, .{ .delete = .{ .path = path, .value = val } });
                    if (p.accept(.comma) == null) break;
                }
            },
            else => return ParseError.Malformed,
        }
    }
    return .{ .arena = arena, .actions = try actions.toOwnedSlice(a) };
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

    fn parseSetAction(self: *Parser) ParseError!Action {
        const path = try self.parseOperand();
        _ = try self.expect(.eq);
        const value = try self.parseSetValue();
        return .{ .set = .{ .path = path, .value = value } };
    }

    fn parseSetValue(self: *Parser) ParseError!SetExpr {
        // Function-call form?
        if (self.peek().kind == .identifier) {
            const next_pos = self.pos + 1;
            if (next_pos < self.toks.len and self.toks[next_pos].kind == .lparen) {
                const fn_tok = self.advance();
                _ = try self.expect(.lparen);
                if (asciiEqlIgnoreCase(fn_tok.text, "if_not_exists")) {
                    const path = try self.parseOperand();
                    _ = try self.expect(.comma);
                    const fallback = try self.parseOperand();
                    _ = try self.expect(.rparen);
                    return .{ .if_not_exists = .{ .path = path, .fallback = fallback } };
                }
                if (asciiEqlIgnoreCase(fn_tok.text, "list_append")) {
                    const lhs = try self.parseOperand();
                    _ = try self.expect(.comma);
                    const rhs = try self.parseOperand();
                    _ = try self.expect(.rparen);
                    return .{ .list_append = .{ .lhs = lhs, .rhs = rhs } };
                }
                return ParseError.UnknownFunction;
            }
        }
        const lhs = try self.parseOperand();
        if (self.accept(.plus)) |_| {
            const rhs = try self.parseOperand();
            return .{ .arith = .{ .lhs = lhs, .op = .add, .rhs = rhs } };
        }
        if (self.accept(.minus)) |_| {
            const rhs = try self.parseOperand();
            return .{ .arith = .{ .lhs = lhs, .op = .subtract, .rhs = rhs } };
        }
        return .{ .operand = lhs };
    }

    fn parseOperand(self: *Parser) ParseError!Operand {
        const t = self.peek();
        switch (t.kind) {
            .identifier => {
                // Reserved-word check fires in operand position only.
                // Function names (if_not_exists / list_append) route through
                // parseSetValue's function-call branch and don't land here.
                if (reserved_words.isReserved(t.text)) return ParseError.ReservedWord;
                _ = self.advance();
                return .{ .name = t.text };
            },
            .name_placeholder => {
                _ = self.advance();
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

// ---------------------------------------------------------------------------
// Applier
//
// Mutates `item.names` / `item.values` in place. All allocations live on
// `allocator` (caller passes the same allocator the item was built with —
// typically a request arena).

pub const ApplyContext = struct {
    allocator: Allocator,
    values: ?std.json.Value,
};

pub fn apply(doc: Document, item: *storage.Item, ctx: ApplyContext) ApplyError!void {
    for (doc.actions) |action| try applyAction(action, item, ctx);
}

fn applyAction(action: Action, item: *storage.Item, ctx: ApplyContext) ApplyError!void {
    switch (action) {
        .set => |s| try applySet(s.path, s.value, item, ctx),
        .remove => |p| try applyRemove(p, item, ctx),
        .add => |a| try applyAdd(a.path, a.value, item, ctx),
        .delete => |d| try applyDelete(d.path, d.value, item, ctx),
    }
}

fn applySet(path: Operand, value: SetExpr, item: *storage.Item, ctx: ApplyContext) ApplyError!void {
    const path_name = switch (path) {
        .name => |n| n,
        else => return ApplyError.TypeMismatch,
    };
    const new_value = try evalSetValue(value, item, ctx);
    try setAttribute(item, path_name, new_value, ctx.allocator);
}

fn evalSetValue(value: SetExpr, item: *storage.Item, ctx: ApplyContext) ApplyError!AttributeValue {
    return switch (value) {
        .operand => |o| try resolveOperand(o, item, ctx) orelse return ApplyError.MissingPlaceholder,
        .arith => |a| blk: {
            const l = try resolveOperand(a.lhs, item, ctx) orelse return ApplyError.MissingPlaceholder;
            const r = try resolveOperand(a.rhs, item, ctx) orelse return ApplyError.MissingPlaceholder;
            if (l != .n or r != .n) return ApplyError.TypeMismatch;
            const lf = std.fmt.parseFloat(f64, l.n) catch return ApplyError.InvalidNumber;
            const rf = std.fmt.parseFloat(f64, r.n) catch return ApplyError.InvalidNumber;
            const result_f = if (a.op == .add) lf + rf else lf - rf;
            const out = std.fmt.allocPrint(ctx.allocator, "{d}", .{result_f}) catch return ApplyError.OutOfMemory;
            break :blk .{ .n = out };
        },
        .if_not_exists => |x| blk: {
            const path_name = switch (x.path) {
                .name => |n| n,
                else => return ApplyError.TypeMismatch,
            };
            if (item.attributeValue(path_name)) |existing| break :blk existing.*;
            break :blk try resolveOperand(x.fallback, item, ctx) orelse return ApplyError.MissingPlaceholder;
        },
        .list_append => |x| blk: {
            const l = try resolveOperand(x.lhs, item, ctx) orelse return ApplyError.MissingPlaceholder;
            const r = try resolveOperand(x.rhs, item, ctx) orelse return ApplyError.MissingPlaceholder;
            const l_items = switch (l) {
                .list => |items| items,
                else => return ApplyError.TypeMismatch,
            };
            const r_items = switch (r) {
                .list => |items| items,
                else => return ApplyError.TypeMismatch,
            };
            const out = ctx.allocator.alloc(AttributeValue, l_items.len + r_items.len) catch return ApplyError.OutOfMemory;
            for (l_items, 0..) |it, i| out[i] = it;
            for (r_items, 0..) |it, i| out[l_items.len + i] = it;
            break :blk .{ .list = out };
        },
    };
}

fn applyRemove(path: Operand, item: *storage.Item, ctx: ApplyContext) ApplyError!void {
    _ = ctx;
    const name = switch (path) {
        .name => |n| n,
        else => return ApplyError.TypeMismatch,
    };
    for (item.names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            // Shift the rest down.
            const mutable_names: [][]const u8 = @constCast(item.names);
            const mutable_values: []AttributeValue = item.values;
            var j: usize = i;
            while (j + 1 < mutable_names.len) : (j += 1) {
                mutable_names[j] = mutable_names[j + 1];
                mutable_values[j] = mutable_values[j + 1];
            }
            item.names = mutable_names[0 .. mutable_names.len - 1];
            item.values = mutable_values[0 .. mutable_values.len - 1];
            return;
        }
    }
}

fn applyAdd(path: Operand, value: Operand, item: *storage.Item, ctx: ApplyContext) ApplyError!void {
    const name = switch (path) {
        .name => |n| n,
        else => return ApplyError.TypeMismatch,
    };
    const delta = try resolveOperand(value, item, ctx) orelse return ApplyError.MissingPlaceholder;

    if (item.attributeValue(name)) |existing_ptr| {
        const existing = existing_ptr.*;
        // Numeric add OR set union.
        if (existing == .n and delta == .n) {
            const cur = std.fmt.parseFloat(f64, existing.n) catch return ApplyError.InvalidNumber;
            const inc = std.fmt.parseFloat(f64, delta.n) catch return ApplyError.InvalidNumber;
            const out = std.fmt.allocPrint(ctx.allocator, "{d}", .{cur + inc}) catch return ApplyError.OutOfMemory;
            try setAttribute(item, name, .{ .n = out }, ctx.allocator);
            return;
        }
        // Set union.
        if (existing == .ss and delta == .ss) {
            try setAttribute(item, name, .{ .ss = try unionSets(ctx.allocator, existing.ss, delta.ss) }, ctx.allocator);
            return;
        }
        if (existing == .ns and delta == .ns) {
            try setAttribute(item, name, .{ .ns = try unionSets(ctx.allocator, existing.ns, delta.ns) }, ctx.allocator);
            return;
        }
        return ApplyError.TypeMismatch;
    }
    // Missing attribute: ADD acts as SET for the initial write.
    try setAttribute(item, name, delta, ctx.allocator);
}

fn applyDelete(path: Operand, value: Operand, item: *storage.Item, ctx: ApplyContext) ApplyError!void {
    const name = switch (path) {
        .name => |n| n,
        else => return ApplyError.TypeMismatch,
    };
    const removal = try resolveOperand(value, item, ctx) orelse return ApplyError.MissingPlaceholder;
    const existing_ptr = item.attributeValue(name) orelse return; // nothing to delete from
    const existing = existing_ptr.*;
    if (existing == .ss and removal == .ss) {
        const kept = try subtractSet(ctx.allocator, existing.ss, removal.ss);
        if (kept.len == 0) try applyRemove(path, item, ctx) else try setAttribute(item, name, .{ .ss = kept }, ctx.allocator);
        return;
    }
    if (existing == .ns and removal == .ns) {
        const kept = try subtractSet(ctx.allocator, existing.ns, removal.ns);
        if (kept.len == 0) try applyRemove(path, item, ctx) else try setAttribute(item, name, .{ .ns = kept }, ctx.allocator);
        return;
    }
    return ApplyError.NotASet;
}

fn unionSets(allocator: Allocator, a: []const []const u8, b: []const []const u8) ApplyError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (a) |s| out.append(allocator, s) catch return ApplyError.OutOfMemory;
    outer: for (b) |s| {
        for (a) |existing| {
            if (std.mem.eql(u8, existing, s)) continue :outer;
        }
        out.append(allocator, s) catch return ApplyError.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch return ApplyError.OutOfMemory;
}

fn subtractSet(allocator: Allocator, a: []const []const u8, b: []const []const u8) ApplyError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (a) |s| {
        for (b) |removed| {
            if (std.mem.eql(u8, removed, s)) continue :outer;
        }
        out.append(allocator, s) catch return ApplyError.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch return ApplyError.OutOfMemory;
}

fn resolveOperand(op: Operand, item: *const storage.Item, ctx: ApplyContext) ApplyError!?AttributeValue {
    return switch (op) {
        .name => |name| blk: {
            const v = item.attributeValue(name) orelse break :blk null;
            break :blk v.*;
        },
        .value_ref => |ref| try resolveValuePlaceholder(ref, ctx),
        .number_literal => |s| .{ .n = s },
        .func_size => null,
    };
}

fn resolveValuePlaceholder(ref: []const u8, ctx: ApplyContext) ApplyError!?AttributeValue {
    const values = ctx.values orelse return ApplyError.MissingPlaceholder;
    if (values != .object) return ApplyError.MissingPlaceholder;
    const json_v = values.object.get(ref) orelse return ApplyError.MissingPlaceholder;
    return av.parseValue(ctx.allocator, json_v) catch return ApplyError.MissingPlaceholder;
}

fn setAttribute(item: *storage.Item, name: []const u8, value: AttributeValue, allocator: Allocator) ApplyError!void {
    // Replace if present, append otherwise.
    for (item.names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            item.values[i] = value;
            return;
        }
    }
    // Grow.
    const mutable_names: [][]const u8 = @constCast(item.names);
    const mutable_values: []AttributeValue = item.values;
    const new_names = allocator.alloc([]const u8, mutable_names.len + 1) catch return ApplyError.OutOfMemory;
    const new_values = allocator.alloc(AttributeValue, mutable_values.len + 1) catch return ApplyError.OutOfMemory;
    for (mutable_names, 0..) |n, i| new_names[i] = n;
    for (mutable_values, 0..) |v, i| new_values[i] = v;
    new_names[mutable_names.len] = allocator.dupe(u8, name) catch return ApplyError.OutOfMemory;
    new_values[mutable_values.len] = value;
    item.names = new_names;
    item.values = new_values;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: SET simple" {
    var doc = try parse(testing.allocator, "SET a = :v", null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.actions.len);
}

test "parse: SET arith" {
    var doc = try parse(testing.allocator, "SET x = x + :inc", null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.actions.len);
}

test "parse: REMOVE + SET" {
    var doc = try parse(testing.allocator, "SET a = :v REMOVE b, c", null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.actions.len); // 1 SET + 2 REMOVE
}

test "parse: ADD on counter" {
    var doc = try parse(testing.allocator, "ADD tally :inc", null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.actions.len);
}
