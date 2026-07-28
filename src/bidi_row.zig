//! Per-row bidi ordering shared by the renderer and the input layer.
//!
//! The renderer uses this to decide which screen column each logical cell is
//! drawn at. The mouse path needs the exact inverse: a click names a screen
//! column, and the terminal has to know which cell of the command line that
//! is. Those two have to agree exactly, including the right-anchor offset and
//! the trailing-blank mirror, so they read from one implementation rather
//! than two that can drift apart.

const std = @import("std");
const terminal = @import("terminal/main.zig");
const bidi_unicode = @import("bidi_unicode.zig");

/// Codepoint used for a cell when resolving a row's bidi order. Cells that
/// render text contribute their codepoint; empty cells, wide-cell spacers,
/// and background-only cells contribute a neutral space so that the bidi
/// indices stay aligned 1:1 with the cell buffer.
pub fn cellCodepointForBidi(cell: *const terminal.page.Cell) u21 {
    return if (cell.hasText()) cell.codepoint() else ' ';
}

/// A row's resolved bidi order: where each logical cell is drawn, plus the
/// embedding levels used to split shaping runs.
pub const BidiRowMap = struct {
    /// logical cell index -> visual screen column. Covers the whole row width,
    /// not just the content, so the cursor can be placed even when it sits
    /// past the last typed character.
    logical_to_visual: []u16,
    /// Embedding levels at logical positions. Only the content span is set.
    levels: []u8,

    pub fn deinit(self: BidiRowMap, alloc: std.mem.Allocator) void {
        alloc.free(self.logical_to_visual);
        alloc.free(self.levels);
    }

    /// Screen column -> logical cell index for this row.
    ///
    /// The inverse of `logical_to_visual`. A click gives a visual column and the
    /// terminal needs the cell of the command line that sits there, which on a
    /// right-to-left row is a different cell entirely.
    ///
    /// Returns null when the column is outside the row.
    pub fn visualToLogical(self: BidiRowMap, visual_x: u16) ?u16 {
        for (self.logical_to_visual, 0..) |v, logical| {
            if (v == visual_x) return @intCast(logical);
        }
        return null;
    }
};

/// Resolve one row's bidi order into a full-width logical->visual map.
///
/// `cps` is the row's content (up to the last cell with text); `cells_len` is
/// the whole row width. `auto` selects the base direction: false forces LTR so
/// the row stays left-anchored, true resolves per-row by UAX #9 first-strong so
/// only genuinely RTL rows mirror.
///
/// Returns null when the bidi resolver fails, which the caller treats as "no
/// reordering" rather than an error.
pub fn bidiRowMap(
    alloc: std.mem.Allocator,
    cps: []const u21,
    cells_len: usize,
    auto: bool,
) !?BidiRowMap {
    const content_len = cps.len;
    if (content_len == 0 or cells_len == 0) return null;

    const resolved = if (auto)
        bidi_unicode.resolveRowAuto(alloc, cps) catch return null
    else
        bidi_unicode.resolveRow(alloc, cps, .ltr) catch return null;
    defer {
        alloc.free(resolved.visual);
        alloc.free(resolved.levels);
    }

    const l2v = try alloc.alloc(u16, cells_len);
    errdefer alloc.free(l2v);
    const lv = try alloc.alloc(u8, cells_len);
    errdefer alloc.free(lv);
    @memset(lv, 0);

    if (resolved.base == .rtl) {
        // Right-anchor: shift the reordered content block to the right edge.
        // offset = free columns to its left.
        const offset: u16 = @intCast(cells_len - content_len);
        for (resolved.visual, 0..) |logical_idx, vis| {
            l2v[logical_idx] = offset + @as(u16, @intCast(vis));
        }
        // The trailing blanks continue the mirror, running right-to-left away
        // from the content: the first blank after the text sits immediately to
        // its LEFT, not at column 0. This is what puts the cursor beside the
        // text in an RTL row.
        var i: usize = content_len;
        while (i < cells_len) : (i += 1) {
            l2v[i] = @intCast(offset - 1 - (i - content_len));
        }
    } else {
        // Left-anchor: content span gets the bidi visual, trailing cells keep
        // identity.
        for (l2v, 0..) |*v, i| v.* = @intCast(i);
        for (resolved.visual, 0..) |logical_idx, vis| l2v[logical_idx] = @intCast(vis);
    }
    @memcpy(lv[0..content_len], resolved.levels);

    return .{ .logical_to_visual = l2v, .levels = lv };
}

test "bidi_row: RTL row right-anchors content and puts the cursor cell beside it" {
    const alloc = std.testing.allocator;
    // "שלום" (4 RTL letters) in a 10 column row.
    const cps = [_]u21{ 0x05E9, 0x05DC, 0x05D5, 0x05DD };
    const cells_len: usize = 10;

    const map = (try bidiRowMap(alloc, &cps, cells_len, true)).?;
    defer map.deinit(alloc);
    const l2v = map.logical_to_visual;

    // Content is right-anchored: the 4 letters occupy the last 4 columns.
    const offset: u16 = @intCast(cells_len - cps.len); // 6
    for (l2v[0..cps.len]) |v| try std.testing.expect(v >= offset);

    // The cell the cursor occupies right after the last typed character is
    // logical index 4, and it must land immediately LEFT of the content block
    // (column 5), not at the far left edge (column 0). This is the regression:
    // it used to map to 0, stranding the cursor across the screen.
    try std.testing.expectEqual(@as(u16, offset - 1), l2v[cps.len]);

    // Subsequent blanks continue leftwards.
    try std.testing.expectEqual(@as(u16, offset - 2), l2v[cps.len + 1]);

    // Every column is used exactly once - the map is a permutation.
    var seen = [_]bool{false} ** 10;
    for (l2v) |v| {
        try std.testing.expect(v < cells_len);
        try std.testing.expect(!seen[v]);
        seen[v] = true;
    }
}

test "bidi_row: LTR row leaves trailing cells at their own columns" {
    const alloc = std.testing.allocator;
    const cps = [_]u21{ 'a', 'b', 'c' };
    const cells_len: usize = 8;

    const map = (try bidiRowMap(alloc, &cps, cells_len, true)).?;
    defer map.deinit(alloc);
    const l2v = map.logical_to_visual;

    // A Latin-first row stays left-anchored, so the cursor after "abc" sits at
    // column 3 exactly where it logically is.
    for (l2v, 0..) |v, i| try std.testing.expectEqual(@as(u16, @intCast(i)), v);
}

test "bidi_row: forced-LTR keeps a Hebrew row left-anchored" {
    const alloc = std.testing.allocator;
    const cps = [_]u21{ 0x05E9, 0x05DC, 0x05D5, 0x05DD };
    const cells_len: usize = 10;

    // auto=false forces the LTR base, i.e. the user's toggle is set to ltr.
    const map = (try bidiRowMap(alloc, &cps, cells_len, false)).?;
    defer map.deinit(alloc);
    const l2v = map.logical_to_visual;

    // The row must not be pushed to the right edge; the trailing cells keep
    // identity so the cursor stays directly after the text.
    try std.testing.expectEqual(@as(u16, @intCast(cps.len)), l2v[cps.len]);
}

test "bidi_row: cursor sits beside the text in a bordered TUI row" {
    const alloc = std.testing.allocator;
    // Models the bordered input box Claude Code draws: a border glyph at both
    // edges means the row's content spans its full width, so the right-anchor
    // offset is zero and the cursor is placed purely by the content's bidi
    // order rather than by the trailing-blank rule.
    const W: usize = 24;
    var cps: [W]u21 = undefined;
    for (&cps) |*c| c.* = ' ';
    cps[0] = 0x2502; // left border
    cps[2] = 0x276F; // prompt
    cps[4] = 0x05D4; // he
    cps[5] = 0x05D9; // yod
    cps[6] = 0x05D9; // yod
    cps[W - 1] = 0x2502; // right border
    const cursor_logical: usize = 7; // right after the last typed letter

    const map = (try bidiRowMap(alloc, &cps, W, true)).?;
    defer map.deinit(alloc);
    const l2v = map.logical_to_visual;

    // The Hebrew reverses into a contiguous block.
    const h0 = l2v[4];
    const h1 = l2v[5];
    const h2 = l2v[6];
    try std.testing.expectEqual(h0, h1 + 1);
    try std.testing.expectEqual(h1, h2 + 1);

    // The cursor belongs immediately to the LEFT of that block, because in an
    // RTL row the insertion point advances leftwards. Landing anywhere else -
    // in particular back at its logical column 7 - is the reported bug.
    const leftmost_hebrew = @min(h0, @min(h1, h2));
    try std.testing.expectEqual(leftmost_hebrew - 1, l2v[cursor_logical]);
    try std.testing.expect(l2v[cursor_logical] != cursor_logical);
}

test "bidi_row: a hyphenated Latin word in an RTL row stays contiguous" {
    const alloc = std.testing.allocator;
    // "אבג max-height" typed on a Hebrew row. The hyphen used to drop to
    // embedding level 0, which cut the paragraph run in two and scattered the
    // word across the row as "max <hebrew> -height".
    const cps = [_]u21{
        0x05D0, 0x05D1, 0x05D2, ' ',
        'm',    'a',    'x',    '-',
        'h',    'e',    'i',    'g',
        'h',    't',
    };
    const cells_len: usize = 40;

    const map = (try bidiRowMap(alloc, &cps, cells_len, true)).?;
    defer map.deinit(alloc);
    const l2v = map.logical_to_visual;

    // The whole Latin span (indices 4..13, hyphen included) is drawn in
    // logical order in consecutive columns.
    var i: usize = 5;
    while (i <= 13) : (i += 1) {
        try std.testing.expectEqual(l2v[i - 1] + 1, l2v[i]);
    }

    // ...and it sits to the LEFT of the Hebrew, which reads right-to-left.
    try std.testing.expect(l2v[13] < l2v[2]);
    try std.testing.expectEqual(l2v[0], l2v[1] + 1);
    try std.testing.expectEqual(l2v[1], l2v[2] + 1);
}

test "bidi_row: a decimal number in an RTL row keeps its digit order" {
    const alloc = std.testing.allocator;
    // "אבג 1.5" used to render the number as "5.1".
    const cps = [_]u21{ 0x05D0, 0x05D1, 0x05D2, ' ', '1', '.', '5' };
    const cells_len: usize = 20;

    const map = (try bidiRowMap(alloc, &cps, cells_len, true)).?;
    defer map.deinit(alloc);
    const l2v = map.logical_to_visual;

    try std.testing.expectEqual(l2v[4] + 1, l2v[5]);
    try std.testing.expectEqual(l2v[5] + 1, l2v[6]);
}

test "bidi_row: visualToLogical inverts the map on an RTL row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // "שלום" in a 10 column row, resolved with the RTL toggle on.
    const cps = [_]u21{ 0x05E9, 0x05DC, 0x05D5, 0x05DD };
    const cells_len: usize = 10;

    const map = (try bidiRowMap(alloc, &cps, cells_len, true)).?;
    defer map.deinit(alloc);

    // Round trip: every logical cell maps to a column that maps back to it.
    // This is the property the mouse depends on, and it is what was missing
    // when a drag over Hebrew selected the wrong cells.
    for (map.logical_to_visual, 0..) |visual, logical| {
        try testing.expectEqual(
            @as(?u16, @intCast(logical)),
            map.visualToLogical(visual),
        );
    }

    // The row reversed, so the mapping is not the identity.
    try testing.expect(map.visualToLogical(0).? != 0);

    // Off the end of the row there is no cell.
    try testing.expectEqual(@as(?u16, null), map.visualToLogical(@intCast(cells_len)));
}

test "bidi_row: visualToLogical is the identity on a latin row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cps = [_]u21{ 'a', 'b', 'c' };
    const map = (try bidiRowMap(alloc, &cps, 8, true)).?;
    defer map.deinit(alloc);

    // A row that never reordered must come back untouched, so Latin text is
    // unaffected by any of this.
    for (0..8) |x| {
        try testing.expectEqual(
            @as(?u16, @intCast(x)),
            map.visualToLogical(@intCast(x)),
        );
    }
}
