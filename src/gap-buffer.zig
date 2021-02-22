// MIT License
//
// Copyright (c) 2020 Luke I. Wilson
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Buffer = std.Buffer;

/// A zero-indexed position of a buffer.
/// `line = 0, col = 0` is the first line, first character.
pub const Position = struct {
    line: usize,
    col:  usize,
};

/// A range between two positions in a buffer. Inclusive.
pub const Range = struct {
    start: Position,
    end:   Position,
};

/// A gap buffer is like a growable array, but the reserved space is
/// in the middle of the data, separating two sides, as opposed to
/// being fixed at the end. This data structure is efficient for
/// inserting and deleting text in close proximity.
pub const GapBuffer = struct {
    const Self = @This();

    data:      ArrayList(u8),
    gap_start: usize,
    gap_len:   usize,

    /// Initialize the GapBuffer with the given string as data.
    ///
    /// This function will verify that the given data is valid UTF-8.
    /// To prevent validation, you can use initUnchecked. An
    /// `error.InvalidUtf8` signals the data was not valid UTF-8.
    pub fn init(allocator: *Allocator, data: []const u8) !GapBuffer {
        // Verify that the provided data is valid UTF-8
        if (!std.unicode.utf8ValidateSlice(data)) {
            return error.InvalidUtf8;
        }

        return initUnchecked(allocator, data);
    }

    /// Initialize the GapBuffer with the given string as data, without validations.
    pub fn initUnchecked(allocator: *Allocator, data: []const u8) !GapBuffer {
        var array_list = try ArrayList(u8).initCapacity(allocator, data.len);
        array_list.expandToCapacity();
        mem.copy(u8, array_list.items[0..data.len], data);
        return GapBuffer{ .data = array_list, .gap_start = data.len, .gap_len = array_list.capacity - data.len };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }

    /// Returns all of the text from the buffer as a new string.
    /// 
    /// The caller is responsible for freeing the returned string.
    pub fn toSlice(self: Self, allocator: *Allocator) ![]const u8 {
        var s1 = self.data.items[0..self.gap_start];
        var s2 = self.data.items[self.gap_start+self.gap_len..];
        var result = try allocator.alloc(u8, s1.len + s2.len);
        mem.copy(u8, result, s1);
        mem.copy(u8, result[s1.len..], s2);
        return result;
    }

    /// Insert text at the given position in the buffer.
    ///
    /// Just like `init`, this function will validate that data
    /// is valid UTF-8.
    ///
    /// If the position does not exist in the buffer, `error.OutOfBounds`
    /// is returned. An `error.OutOfMemory` is possible here. In addition,
    /// an error from `findOffset` may be returned also.
    pub fn insert(self: *Self, data: []const u8, pos: Position) !void {
        // Verify that the provided data is valid UTF-8
        if (!std.unicode.utf8ValidateSlice(data)) {
            return error.InvalidUtf8;
        }

        return insertUnchecked(self, data, pos);
    }

    /// Insert text at the given position in the buffer, without validations.
    pub fn insertUnchecked(self: *Self, data: []const u8, pos: Position) !void {
        if (data.len > self.gap_len) { // If we need to allocate more memory ...
            self.moveGap(self.data.capacity); // Move gap to end

            try self.data.resize(self.data.capacity + (data.len - self.gap_len)); // Increase gap buffer size to fit requirement
            self.data.expandToCapacity(); // Make item count equal to available allocated space

            self.gap_len = self.data.capacity - self.gap_start; // Extend gap length to max available
        }

        var offset = self.findOffset(pos) orelse return error.OutOfBounds;
        self.moveGap(offset);
        self.writeToGap(data);
    }

    /// Returns the specified range of data from the buffer as a new string. Inclusive.
    ///
    /// If any part of the range is not found in the buffer, a null value will be returned.
    ///
    /// The caller is responsible for freeing the returned string.
    pub fn read(self: Self, allocator: *Allocator, range: Range) !?[]const u8 {
        var start_offset = self.findOffset(range.start) orelse return null;
        var end_offset = self.findOffset(range.end) orelse return null;

        if (start_offset < self.gap_start and self.gap_start < end_offset) { // If the gap is between the two positions ...
            var s1 = self.data.items[start_offset..self.gap_start]; // First half
            var s2 = self.data.items[self.gap_start+self.gap_len..end_offset+1]; // Second half

            var str = try allocator.alloc(u8, s1.len + s2.len);

            mem.copy(u8, str, s1);
            mem.copy(u8, str[s1.len..], s2);

            return str;
        } else {
            // No gap in the way, just return the requested data range
            var s = self.data.items[start_offset..end_offset+1];

            var str = try allocator.alloc(u8, s.len);
            mem.copy(u8, str, s);

            return str;
        }
    }

    /// Removes the range of data from the buffer. Inclusive.
    pub fn delete(self: *Self, range: Range) void {
        var start_offset = self.findOffset(range.start) orelse return;
        self.moveGap(start_offset);

        var end_offset = self.findOffset(range.end) orelse return;
        self.gap_len = end_offset - self.gap_start + 1; // Widen gap in order to cover deleted contents
    }

    /// On the assumption that the gap is large enough to support the
    /// length of the data, this function will write it into the gap,
    /// decreasing the size of the gap in the process.
    fn writeToGap(self: *Self, data: []const u8) void {
        std.debug.assert(data.len <= self.gap_len);

        // Write data to the gap
        mem.copy(u8, self.data.items[self.gap_start..], data);
        // Shrink the gap
        self.gap_start += data.len;
        self.gap_len -= data.len;
    }

    /// Returns true if the provided character position could be found in the buffer.
    pub fn inBounds(self: Self, pos: Position) bool {
        return self.findOffset(pos) != null;
    }

    /// Maps a position to its offset in the data. Remember: positions are zero-based.
    /// For example, `.{.line=2, .col=3}` is the fourth character of the third line.
    ///
    /// The error returned could be `error.InvalidUtf8`. If the value returned is null,
    /// then the character position you provided was not found in the buffer.
    pub fn findOffset(self: Self, pos: Position) ?usize {
        var first_half = self.data.items[0..self.gap_start];
        var line: usize = 0;
        var col: usize = 0;

        var iter = std.unicode.Utf8View.initUnchecked(first_half).iterator();
        var offset: usize = 0;
        while (iter.nextCodepointSlice()) |c| : (offset += c.len) {
            if (line == pos.line and col == pos.col) return offset; // Have we found the correct position?

            if (mem.eql(u8, c, "\n")) {
                line += 1;
                col = 0;
            } else {
                col += 1;
            }
        }

        // If the position wasn't in the first half, it could be at the start of the gap
        if (line == pos.line and col == pos.col) return self.gap_start + self.gap_len;

        var second_half = self.data.items[self.gap_start+self.gap_len..];
        iter = std.unicode.Utf8View.initUnchecked(second_half).iterator();
        offset = 0;
        while (iter.nextCodepointSlice()) |c| : (offset += c.len) {
            if (line == pos.line and col == pos.col) return self.gap_start + self.gap_len + offset; // Have we found the correct position?

            if (mem.eql(u8, c, "\n")) {
                line += 1;
                col = 0;
            } else {
                col += 1;
            }
        }

        // If the position wasn't in the second half, it could be at the end of the buffer
        if (line == pos.line and col == pos.col) return self.data.items.len;

        return null;
    }

    /// Moves closest boundary of the gap to the given index of the data.
    fn moveGap(self: *Self, offset: usize) void {
        if (self.gap_len == 0) { // If we're at full capacity, no need to move any data
            self.gap_start = offset;
            return;
        }

        if (offset < self.gap_start) { // If we need to move the gap to the left ...
            var i: usize = self.gap_start - 1;
            while (i >= offset) : (i -= 1) {
                self.data.items[i + self.gap_len] = self.data.items[i]; // Move items from left side to right side
                self.data.items[i] = 0; // Make characters within gap null bytes
            }
            self.gap_start = offset;
        } else if (offset > self.gap_start) { // If we need to move the gap to the right ...
            var i: usize = self.gap_start + self.gap_len; // Only moving enough to get right boundary in place
            while (i < offset) : (i += 1) {
                self.data.items[i - self.gap_len] = self.data.items[i]; // Move items from right side to left side
                self.data.items[i] = 0;
            }
            self.gap_start = offset - self.gap_len;
        }
    }
};

test "basic init and moving the gap" {
    const alloc = testing.allocator;

    var gb = try GapBuffer.init(alloc, "this is a test");
    defer gb.deinit();

    gb.moveGap(3); // Set gap start position to index 3
    testing.expect(gb.gap_start == 3);
}

test "utf-8" {
    const alloc = testing.allocator;

    var gb = try GapBuffer.init(alloc, "鶸膱𩋍ꈵO֫窄|̋喛\\ꜯnG"); // Random UTF-8 string
    defer gb.deinit();

    var offset = gb.findOffset(.{.line = 0, .col = 6}); // Get the starting index of the SEVENTH character
    testing.expect(offset.? == 16);
}

test "lines and columns" {
    const alloc = testing.allocator;

    var gb = try GapBuffer.init(alloc, "first\n    second\n\t\tthird\n\nfifth");
    defer gb.deinit();

    var offset = gb.findOffset(.{.line = 1, .col = 4}); // Get the first letter of word "second" (0-indexed)
    testing.expect(offset.? == 10);

    offset = gb.findOffset(.{.line = 2, .col = 2}); // Get the first letter of word "third"
    testing.expect(offset.? == 19);

    offset = gb.findOffset(.{.line = 4, .col = 0}); // Get the first letter of word "third"
    testing.expect(offset.? == 26);
}

test "inBounds" {
    const alloc = testing.allocator;

    var gb = try GapBuffer.init(alloc, "鶸膱𩋍ꈵO֫窄|̋喛\\ꜯnG"); // Random UTF-8 string
    defer gb.deinit();

    testing.expect(gb.inBounds(.{.line = 0, .col = 7}) == true);
    testing.expect(gb.inBounds(.{.line = 0, .col = 16}) == false);
    testing.expect(gb.inBounds(.{.line = 1, .col = 0}) == false);
}

test "read from ranges" {
    const alloc = testing.allocator;

    var gb = try GapBuffer.init(alloc, "first\n    second\n\t\tthird\n\nfifth");
    defer gb.deinit();

    const pos = Range { .start=.{ .line=1,.col=0}, .end=.{.line=2,.col=7} };
    var lines_2_and_3 = try gb.read(alloc, pos);
    defer alloc.free(lines_2_and_3.?);

    testing.expectEqualStrings(lines_2_and_3.?, "    second\n\t\tthird\n");
}

test "inserting and deleting text" {
    const alloc = testing.allocator;

    var gb = try GapBuffer.init(alloc, "init");
    defer gb.deinit();

    try gb.insert("ial text", .{.line=0,.col=4});
    var tmp1 = try gb.toSlice(alloc);
    defer alloc.free(tmp1);
    testing.expectEqualStrings(tmp1, "initial text");

    gb.delete(.{ .start = .{ .line = 0, .col = 4 }, .end = .{ .line = 0, .col = 6 } });
    var tmp2 = try gb.toSlice(alloc);
    defer alloc.free(tmp2);
    testing.expectEqualStrings(tmp2, "init text");

    try gb.insert(" sequence! :)", Position { .line = 0, .col = 9 });
    var tmp3 = try gb.toSlice(alloc);
    defer alloc.free(tmp3);
    testing.expectEqualStrings(tmp3, "init text sequence! :)");
}
