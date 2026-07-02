const std = @import("std");
const bidi = @import("bidi.zig");
const unicode = @import("unicode/main.zig");
const uucode = @import("uucode");

/// Map Unicode Bidi_Class to the engine's reduced Class set.
/// Explicit embeddings/overrides/isolates (X-rules, out of M1 scope) and any
/// unmodeled class fall through to neutral (.other_neutrals).
pub fn classOf(cp: u21) bidi.Class {
    return switch (unicode.table.get(cp).bidi_class) {
        .left_to_right => .left_to_right,
        .right_to_left => .right_to_left,
        .right_to_left_arabic => .right_to_left_arabic,
        .european_number => .european_number,
        .arabic_number => .arabic_number,
        .european_number_separator => .european_number_separator,
        .european_number_terminator => .european_number_terminator,
        .common_number_separator => .common_number_separator,
        .nonspacing_mark => .nonspacing_mark,
        .boundary_neutral => .boundary_neutral,
        .paragraph_separator => .paragraph_separator,
        .segment_separator => .segment_separator,
        .whitespace => .whitespace,
        .other_neutrals => .other_neutrals,
        else => .other_neutrals, // LRE/RLE/LRO/RLO/PDF/LRI/RLI/FSI/PDI → neutral in M1
    };
}

/// Resolve a row of codepoints (logical order) to visual order + levels.
/// Caller frees `.levels` and `.visual`.
pub fn resolveRow(alloc: std.mem.Allocator, codepoints: []const u21, base: bidi.Direction) !bidi.Resolved {
    const classes = try alloc.alloc(bidi.Class, codepoints.len);
    defer alloc.free(classes);
    for (codepoints, 0..) |cp, i| classes[i] = classOf(cp);
    return bidi.resolveClasses(alloc, classes, base);
}

/// Like `resolveRow` but picks the base direction per row via UAX#9 P2/P3
/// (first strong character). A Hebrew/Arabic-first row resolves rtl (and is
/// right-anchored by the renderer); a Latin-first row resolves ltr (left).
pub fn resolveRowAuto(alloc: std.mem.Allocator, codepoints: []const u21) !bidi.Resolved {
    const classes = try alloc.alloc(bidi.Class, codepoints.len);
    defer alloc.free(classes);
    for (codepoints, 0..) |cp, i| classes[i] = classOf(cp);
    return bidi.resolveClasses(alloc, classes, bidi.baseDirection(classes));
}

test "resolveRow hebrew word reverses" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // U+05D0 U+05D1 U+05D2 (3 Hebrew letters): forced LTR base (left-anchored),
    // but the RTL run is reversed internally so the word reads correctly.
    const r = try resolveRow(alloc, &.{ 0x05D0, 0x05D1, 0x05D2 }, .ltr);
    defer alloc.free(r.levels);
    defer alloc.free(r.visual);
    try testing.expectEqual(bidi.Direction.ltr, r.base);
    try testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, r.visual);
}

test "resolveRow mixed english hebrew" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // "a" + heb + heb + "b" : indices 0,1,2,3 ; visual 0,2,1,3
    const r = try resolveRow(alloc, &.{ 'a', 0x05D0, 0x05D1, 'b' }, .ltr);
    defer alloc.free(r.levels);
    defer alloc.free(r.visual);
    try testing.expectEqual(bidi.Direction.ltr, r.base);
    try testing.expectEqualSlices(u16, &.{ 0, 2, 1, 3 }, r.visual);
}

test "resolveRowAuto: hebrew-first row resolves rtl base" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const r = try resolveRowAuto(alloc, &.{ 0x05D0, 0x05D1, ' ', 'a' });
    defer alloc.free(r.levels);
    defer alloc.free(r.visual);
    try testing.expectEqual(bidi.Direction.rtl, r.base);
}

test "resolveRowAuto: latin-first row resolves ltr base" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const r = try resolveRowAuto(alloc, &.{ 'h', 'i', ' ', 0x05D0 });
    defer alloc.free(r.levels);
    defer alloc.free(r.visual);
    try testing.expectEqual(bidi.Direction.ltr, r.base);
}
