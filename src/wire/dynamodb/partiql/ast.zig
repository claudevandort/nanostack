//! PartiQL AST for DynamoDB (v0.2.4).
//!
//! Statements: SELECT / INSERT / UPDATE / DELETE. Phase 1 ships SELECT.
//! Phases 2 + 3 fill in the other variants.
//!
//! Design note: the AST is **lightweight on purpose**. The PartiQL
//! WHERE / SET grammars are isomorphic to DDB ConditionExpression /
//! UpdateExpression, so most of the heavy lifting (comparison, set
//! arithmetic, list_append, attribute-path resolution) already exists
//! in `src/wire/dynamodb/expressions/`. The PartiQL parser identifies
//! statement structure + extracts predicates as small native ASTs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const attribute_value = @import("../attribute_value.zig");
pub const AttributeValue = attribute_value.AttributeValue;

/// Operand inside a predicate or SET action: either an inline literal
/// or a positional `?` parameter (resolved at eval time from the
/// request's `Parameters` array).
pub const Operand = union(enum) {
    /// Literal AttributeValue parsed from inline syntax.
    literal: AttributeValue,
    /// 0-based index into `Parameters`.
    param_index: u32,
};

/// One column name (qualified for projection: `col` or `*`).
pub const ColumnRef = union(enum) {
    star,
    name: []const u8,
};

pub const SortPredicateKind = enum { eq, lt, le, gt, ge, between, begins_with };

pub const SortPredicate = union(SortPredicateKind) {
    eq: Operand,
    lt: Operand,
    le: Operand,
    gt: Operand,
    ge: Operand,
    between: struct { lo: Operand, hi: Operand },
    begins_with: Operand,
};

/// Phase 1 WHERE shape: a key-condition (PK eq + optional SK predicate).
/// Phase 2 extends this to a richer condition AST.
pub const KeyCondition = struct {
    pk_name: []const u8,
    pk_value: Operand,
    sk_name: ?[]const u8 = null,
    sk_predicate: ?SortPredicate = null,
};

pub const Select = struct {
    table_name: []const u8,
    /// Set when the statement uses `FROM "table"."index"` syntax.
    index_name: ?[]const u8 = null,
    /// Either a single `.star` entry or a projection list.
    columns: []const ColumnRef,
    /// Phase 1: either a KeyCondition or null (full scan).
    where_clause: ?KeyCondition = null,
};

/// One entry of an INSERT's VALUE map.
pub const InsertField = struct {
    name: []const u8,
    value: Operand,
};

pub const Insert = struct {
    table_name: []const u8,
    fields: []const InsertField,
};

/// One SET assignment inside UPDATE. Either a direct value or
/// "col + operand" / "col - operand" for atomic counters.
pub const UpdateOp = enum { assign, add_to_col, sub_from_col };

pub const UpdateAssignment = struct {
    column: []const u8,
    op: UpdateOp,
    operand: Operand,
};

/// AWS RETURNING modifier on UPDATE / DELETE. Maps to the underlying
/// `ReturnValues` field on the storage op.
pub const ReturnValues = enum {
    none,
    all_old,
    all_new,
    updated_old,
    updated_new,
};

pub const Update = struct {
    table_name: []const u8,
    assignments: []const UpdateAssignment,
    where_clause: KeyCondition,
    returning: ReturnValues = .none,
};

pub const Delete = struct {
    table_name: []const u8,
    where_clause: KeyCondition,
    returning: ReturnValues = .none,
};

pub const Statement = union(enum) {
    select: Select,
    insert: Insert,
    update: Update,
    delete: Delete,
};

/// Output of the parser: the AST + a count of `?` parameters seen, so
/// the handler can validate `Parameters.len == placeholder_count`.
pub const ParsedStatement = struct {
    statement: Statement,
    placeholder_count: u32,
};
