# Zig Gap Buffer
A gap buffer implementation for Zig, designed to be idiomatic. The design of this code is styled after the standard library.

Feel free to just copy the gap-buffer.zig source file to your project if you'd rather.

## What is a Gap Buffer?
A [gap buffer](https://en.wikipedia.org/wiki/Gap_buffer) is like a growable array, but the reserved space is in the middle of the data, separating two sides, as opposed to being fixed at the end. This data structure is efficient for inserting and deleting data in close proximity. Gap buffers are commonly used in text editors as a simpler method than, say, [ropes](https://en.wikipedia.org/wiki/Rope_(data_structure)).

On each side of the gap is a string. The gap of the gap buffer should be at the same location as the cursor in the text editor. When the cursor moves, the gap moves. Moving the cursor causes no allocation because it is moving data from the right side of the gap to the left side. Inserting text appends to the data on the left side, shrinking the gap. Deleting text grows the gap. When data inserted exceeds the gap size, more space is allocated.

Gap buffers are not efficient for large files. For more information, see [the Gap Buffer Wikipedia article](https://en.wikipedia.org/wiki/Gap_buffer).

## Examples

There are several examples of usage in the test section at the bottom of the `gap-buffer.zig` source file.

But basically, here's your getting started:

```zig
const std = @import("std");
const GapBuffer = @import("gap-buffer").GapBuffer;

pub fn main() void {
    // Whatever allocator you wish to use ...
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var gb = try GapBuffer.init(&arena.allocator, "");
    // defer gb.deinit(); // Arena frees data automatically

    // Insert some text into the currently empty buffer
    try gb.insert("some text", .{ .line = 0, .col = 0 });

    var text = try gb.toSlice(&arena.allocator); // Don't forget to free the string
    std.debug.warn("{}\n", .{text}); // "some text"
}
```
