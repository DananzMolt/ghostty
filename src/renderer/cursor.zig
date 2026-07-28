const std = @import("std");
const terminal = @import("../terminal/main.zig");

/// Available cursor styles for drawing that renderers must support.
/// This is a superset of terminal cursor styles since the renderer supports
/// some additional cursor states such as the hollow block.
pub const Style = enum {
    // Typical cursor input styles
    block,
    block_hollow,
    bar,
    underline,

    // Special cursor styles
    lock,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(term: terminal.CursorStyle) Style {
        return switch (term) {
            .bar => .bar,
            .block => .block,
            .block_hollow => .block_hollow,
            .underline => .underline,
        };
    }
};

pub const StyleOptions = struct {
    preedit: bool = false,
    focused: bool = false,
    blink_visible: bool = false,

    /// Hide the cursor while a selection is active. See the note in `style`.
    hide_while_selecting: bool = false,
};

/// Returns the cursor style to use for the current render state or null
/// if a cursor should not be rendered at all.
pub fn style(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) ?Style {
    // Note the order of conditionals below is important. It represents
    // a priority system of how we determine what state overrides cursor
    // visibility and style.

    // The cursor must be visible in the viewport to be rendered.
    if (state.cursor.viewport == null) return null;

    // If we are in preedit, then we always show the block cursor. We do
    // this even if the cursor is explicitly not visible because it shows
    // an important editing state to the user.
    if (opts.preedit) return .block;

    // If we're at a password input its always a lock.
    if (state.cursor.password_input) return .lock;

    // While there is a selection, the selection is the editing intent: the
    // next keystroke acts on it rather than at the cursor. Drawing both
    // invites the reader to believe typing will land at the cursor, and the
    // block cursor sitting inside the highlight is just visual noise.
    //
    // Ranked below preedit and password input, which are states the user
    // needs to see even mid-selection.
    if (opts.hide_while_selecting and state.selection_active) return null;

    // If the cursor is explicitly not visible by terminal mode, we don't render.
    if (!state.cursor.visible) return null;

    // If we're not focused, our cursor is always visible so that
    // we can show the hollow box.
    if (!opts.focused) return .block_hollow;

    // If the cursor is blinking and our blink state is not visible,
    // then we don't show the cursor.
    if (state.cursor.blinking and !opts.blink_visible) return null;

    // Otherwise, we use whatever style the terminal wants.
    return .fromTerminal(state.cursor.visual_style);
}

test "cursor: default uses configured style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term: terminal.Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = false }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = false }) == null);
}

test "cursor: blinking disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == .block_hollow);
}

test "cursor: explicitly not visible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, false);
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == null);
}

test "cursor: always block with preedit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == .block);

    // If we're scrolled though, then we don't show the cursor.
    for (0..100) |_| try term.index();
    term.scrollViewport(.{ .top = {} });
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == null);
}

test "cursor: hidden while a selection is active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term: terminal.Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    // Baseline: visible with no selection.
    try testing.expect(style(&state, .{
        .focused = true,
        .blink_visible = true,
        .hide_while_selecting = true,
    }) != null);

    state.selection_active = true;

    // Hidden once something is selected...
    try testing.expect(style(&state, .{
        .focused = true,
        .blink_visible = true,
        .hide_while_selecting = true,
    }) == null);

    // ...but only when the option is on.
    try testing.expect(style(&state, .{
        .focused = true,
        .blink_visible = true,
        .hide_while_selecting = false,
    }) != null);
}

test "cursor: preedit and password outrank a selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term: terminal.Terminal = try .init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);
    state.selection_active = true;

    // Composing text still needs its cursor.
    try testing.expectEqual(Style.block, style(&state, .{
        .preedit = true,
        .focused = true,
        .blink_visible = true,
        .hide_while_selecting = true,
    }).?);

    // So does a password prompt, which uses the cursor as its indicator.
    state.cursor.password_input = true;
    try testing.expectEqual(Style.lock, style(&state, .{
        .focused = true,
        .blink_visible = true,
        .hide_while_selecting = true,
    }).?);
}
