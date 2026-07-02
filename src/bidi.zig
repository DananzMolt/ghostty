//! Unicode Bidirectional Algorithm (UAX #9) implicit-resolution subset.
//!
//! Milestone 1 (render-only): this module is fully self-contained and depends
//! only on `std`. It operates on a sequence of `Class` values (Bidi_Class
//! property of each codepoint) and produces:
//!   - the paragraph base direction (P2/P3),
//!   - per-character embedding levels (implicit subset of X/W/N rules),
//!   - and the L2 visual reordering map.
//!
//! Explicit embeddings, overrides, and isolates (LRE/RLE/PDF/LRI/RLI/FSI/PDI)
//! are NOT processed; if such formatting codepoints are present, the
//! integration layer should map them to a neutral class (e.g. `other_neutrals`
//! or `boundary_neutral`) and they will be resolved as neutrals.

const std = @import("std");
const testing = std.testing;

/// Visual/base direction.
pub const Direction = enum(u1) { ltr, rtl };

/// Bidirectional character class (UAX #9). Mirror of the Unicode Bidi_Class
/// property. Kept local so this module stays std-only and unit-testable.
pub const Class = enum {
    left_to_right, // L
    right_to_left, // R
    right_to_left_arabic, // AL
    european_number, // EN
    arabic_number, // AN
    european_number_separator, // ES
    european_number_terminator, // ET
    common_number_separator, // CS
    nonspacing_mark, // NSM
    boundary_neutral, // BN
    paragraph_separator, // B
    segment_separator, // S
    whitespace, // WS
    other_neutrals, // ON
};

/// Base direction from the FIRST strong character (UAX #9 P2/P3): if the
/// sentence starts with a Hebrew/Arabic (R/AL) letter it reads right-to-left,
/// if it starts with a Latin (L) letter it reads left-to-right. Leading
/// neutrals/numbers are skipped; no strong char defaults to ltr.
pub fn baseDirection(classes: []const Class) Direction {
    for (classes) |c| {
        switch (c) {
            .left_to_right => return .ltr,
            .right_to_left, .right_to_left_arabic => return .rtl,
            else => {},
        }
    }
    return .ltr;
}

test "baseDirection: first strong char wins" {
    // first strong is L -> ltr (even with later RTL)
    try testing.expectEqual(Direction.ltr, baseDirection(&.{ .left_to_right, .right_to_left, .right_to_left }));
    // first strong is R -> rtl (even with later LTR)
    try testing.expectEqual(Direction.rtl, baseDirection(&.{ .right_to_left, .left_to_right, .left_to_right }));
    // leading neutrals skipped, first strong R -> rtl
    try testing.expectEqual(Direction.rtl, baseDirection(&.{ .whitespace, .right_to_left, .left_to_right }));
    // arabic counts as rtl
    try testing.expectEqual(Direction.rtl, baseDirection(&.{.right_to_left_arabic}));
    // no strong chars -> ltr
    try testing.expectEqual(Direction.ltr, baseDirection(&.{ .whitespace, .european_number }));
}

/// A class is "neutral" if it has no inherent strong direction and must be
/// resolved from surrounding context. For the M1 subset this includes the
/// neutral and separator classes plus boundary neutrals.
fn isNeutral(c: Class) bool {
    return switch (c) {
        .european_number_separator,
        .european_number_terminator,
        .common_number_separator,
        .nonspacing_mark,
        .boundary_neutral,
        .paragraph_separator,
        .segment_separator,
        .whitespace,
        .other_neutrals,
        => true,
        else => false,
    };
}

/// The strong direction a class contributes to neutral resolution.
/// Strong L is ltr; R/AL are rtl. For neutral runs, numbers (EN/AN) act as
/// rtl boundaries per UAX #9 N1 (an EN/AN counts as R for neutral resolution).
/// Returns null for neutrals (which have no strong direction of their own).
fn strongDir(c: Class) ?Direction {
    return switch (c) {
        .left_to_right => .ltr,
        .right_to_left, .right_to_left_arabic => .rtl,
        .european_number, .arabic_number => .rtl,
        else => null,
    };
}

/// Resolve neutral runs in place (UAX #9 N1/N2 subset).
///
/// A maximal run of neutral characters takes the direction of the surrounding
/// strong context if both sides agree (sequence boundaries count as the base
/// direction); otherwise it takes the base direction. `levels` is updated for
/// each resolved neutral: ltr -> even base level, rtl -> base_level | 1.
fn resolveNeutrals(classes: []const Class, base: Direction, levels: []u8) void {
    const base_level: u8 = if (base == .rtl) 1 else 0;
    var i: usize = 0;
    while (i < classes.len) {
        if (!isNeutral(classes[i])) {
            i += 1;
            continue;
        }
        // Find the maximal neutral run [i, j).
        var j = i;
        while (j < classes.len and isNeutral(classes[j])) j += 1;

        // Direction before the run (sequence start counts as base).
        var before: Direction = base;
        if (i > 0) {
            if (strongDir(classes[i - 1])) |d| before = d;
        }
        // Direction after the run (sequence end counts as base).
        var after: Direction = base;
        if (j < classes.len) {
            if (strongDir(classes[j])) |d| after = d;
        }

        const resolved: Direction = if (before == after) before else base;
        const lvl: u8 = if (resolved == .rtl) (base_level | 1) else (base_level & ~@as(u8, 1));
        var k = i;
        while (k < j) : (k += 1) levels[k] = lvl;
        i = j;
    }
}

/// Compute per-character embedding levels (UAX #9 implicit subset).
///
/// `out_levels.len` must equal `classes.len`.
///   - base_level = 1 (rtl) or 0 (ltr).
///   - L  -> smallest even level >= base_level.
///   - R/AL -> smallest odd level >= base_level.
///   - EN/AN -> rendered LTR at the smallest even level >= base_level (so in
///     an rtl paragraph that is level 2, keeping digits in logical order).
///   - neutrals -> resolved by `resolveNeutrals`.
pub fn resolveLevels(classes: []const Class, base: Direction, out_levels: []u8) void {
    std.debug.assert(out_levels.len == classes.len);
    const base_level: u8 = if (base == .rtl) 1 else 0;
    const even_at_or_above: u8 = if (base_level % 2 == 0) base_level else base_level + 1;
    const odd_at_or_above: u8 = if (base_level % 2 == 1) base_level else base_level + 1;

    for (classes, 0..) |c, idx| {
        out_levels[idx] = switch (c) {
            .left_to_right => even_at_or_above,
            .right_to_left, .right_to_left_arabic => odd_at_or_above,
            .european_number, .arabic_number => even_at_or_above,
            else => base_level, // placeholder; fixed by resolveNeutrals
        };
    }

    resolveNeutrals(classes, base, out_levels);
}

test "resolveLevels: mixed LTR base {L,R,L} -> {0,1,0}" {
    var levels: [3]u8 = undefined;
    resolveLevels(&.{ .left_to_right, .right_to_left, .left_to_right }, .ltr, &levels);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0 }, &levels);
}

test "resolveLevels: number in RTL {R,EN,R} base rtl -> {1,2,1}" {
    var levels: [3]u8 = undefined;
    resolveLevels(&.{ .right_to_left, .european_number, .right_to_left }, .rtl, &levels);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 1 }, &levels);
}

test "resolveLevels: neutral between RTL {R,WS,R} base rtl -> {1,1,1}" {
    var levels: [3]u8 = undefined;
    resolveLevels(&.{ .right_to_left, .whitespace, .right_to_left }, .rtl, &levels);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1 }, &levels);
}

/// UAX #9 L2: produce the logical-index-by-visual-position map.
///
/// `out_visual.len` must equal `levels.len`. Initializes `out_visual[i] = i`,
/// then from the highest level down to the lowest odd level, reverses each
/// contiguous run of characters whose level is >= the current level. After
/// reordering, `out_visual[visualPos]` is the logical index drawn at that
/// visual position.
pub fn reorder(levels: []const u8, out_visual: []u16) void {
    std.debug.assert(out_visual.len == levels.len);
    for (out_visual, 0..) |*v, i| v.* = @intCast(i);
    if (levels.len == 0) return;

    var highest: u8 = 0;
    var lowest_odd: u8 = std.math.maxInt(u8);
    for (levels) |lvl| {
        if (lvl > highest) highest = lvl;
        if (lvl % 2 == 1 and lvl < lowest_odd) lowest_odd = lvl;
    }
    if (lowest_odd == std.math.maxInt(u8)) return; // no odd levels, nothing to reverse

    var level = highest;
    while (level >= lowest_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < levels.len) {
            if (levels[i] < level) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < levels.len and levels[j] >= level) j += 1;
            // Reverse the run [i, j) within out_visual.
            std.mem.reverse(u16, out_visual[i..j]);
            i = j;
        }
        if (level == 0) break; // guard against u8 underflow
    }
}

test "reorder: pure RTL {1,1,1} -> {2,1,0}" {
    var visual: [3]u16 = undefined;
    reorder(&.{ 1, 1, 1 }, &visual);
    try testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, &visual);
}

test "reorder: mixed {0,1,1,0} -> {0,2,1,3}" {
    var visual: [4]u16 = undefined;
    reorder(&.{ 0, 1, 1, 0 }, &visual);
    try testing.expectEqualSlices(u16, &.{ 0, 2, 1, 3 }, &visual);
}

test "reorder: number in RTL {1,2,2,1} -> {3,1,2,0}" {
    var visual: [4]u16 = undefined;
    reorder(&.{ 1, 2, 2, 1 }, &visual);
    try testing.expectEqualSlices(u16, &.{ 3, 1, 2, 0 }, &visual);
}

/// Result of fully resolving a sequence of bidi classes. `levels` and `visual`
/// are heap-allocated; the caller owns them and must free both with the same
/// allocator passed to `resolveClasses`.
pub const Resolved = struct {
    levels: []u8,
    visual: []u16,
    base: Direction,
};

/// Run the full implicit pipeline (P2/P3 -> levels -> L2) over a sequence of
/// bidi classes. Pure: operates on classes, not codepoints. Allocates `levels`
/// and `visual`; the caller frees both.
pub fn resolveClasses(alloc: std.mem.Allocator, classes: []const Class, base: Direction) !Resolved {
    const levels = try alloc.alloc(u8, classes.len);
    errdefer alloc.free(levels);
    const visual = try alloc.alloc(u16, classes.len);
    errdefer alloc.free(visual);

    // `base` is the explicit paragraph base direction (set by the caller from
    // the `bidi-direction` config): .ltr keeps the line left-anchored (Latin
    // terminal), .rtl right-anchors and mirrors it (Hebrew/Arabic terminal).
    // Either way, bidi reverses each RTL run internally so words keep correct
    // letter order. We deliberately do NOT auto-pick base from first-strong;
    // the direction is a user toggle, not content-derived.
    resolveLevels(classes, base, levels);
    reorder(levels, visual);

    return .{ .levels = levels, .visual = visual, .base = base };
}

test "resolveClasses: all RTL, forced LTR base -> reversed run, visual {2,1,0}" {
    // Forced LTR base. All-RTL row still gets level 1 and is reversed by L2
    // (word reads correctly), but the line stays left-anchored (base ltr).
    const classes = [_]Class{ .right_to_left, .right_to_left, .right_to_left };
    const res = try resolveClasses(testing.allocator, &classes, .ltr);
    defer testing.allocator.free(res.levels);
    defer testing.allocator.free(res.visual);

    try testing.expectEqual(Direction.ltr, res.base);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1 }, res.levels);
    try testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, res.visual);
}

test "resolveClasses: mixed LTR run, RTL base -> level 2 run, right-to-left order" {
    // RTL base: an embedded LTR run sits at level 2 (even, reads L->R) inside
    // the level-1 paragraph, and L2 reverses the paragraph so it right-anchors.
    const classes = [_]Class{ .left_to_right, .left_to_right, .right_to_left };
    const res = try resolveClasses(testing.allocator, &classes, .rtl);
    defer testing.allocator.free(res.levels);
    defer testing.allocator.free(res.visual);

    try testing.expectEqual(Direction.rtl, res.base);
    try testing.expectEqualSlices(u8, &.{ 2, 2, 1 }, res.levels);
    // `visual` is visual->logical (visual[pos] = logical drawn there). RTL base
    // puts the R cell (logical 2) at the left, then the LTR pair in order.
    try testing.expectEqualSlices(u16, &.{ 2, 0, 1 }, res.visual);
}
