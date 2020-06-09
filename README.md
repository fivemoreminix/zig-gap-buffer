# Zig Gap Buffer
A gap buffer implementation for Zig. This library provides only the gap buffer data structure but no high-level wrapper type over it.

## What is a Gap Buffer?
A [gap buffer](https://en.wikipedia.org/wiki/Gap_buffer) is like a growable array, but the reserved space is in the middle of the data, separating two sides, as opposed to being fixed at the end. This data structure is efficient for inserting and deleting data in close proximity. Gap buffers are commonly used in text editors as a simpler method than, say, [ropes](https://en.wikipedia.org/wiki/Rope_(data_structure)).

On each side of the gap is a string. The gap of the gap buffer should be at the same location as the cursor in the text editor. When the cursor moves, the gap moves. Moving the cursor causes no allocation because it is moving data from the right side of the gap to the left side. Inserting text appends to the data on the left side, deleting text removes data on the left side. When data on the left exceeds the gap space, more space is allocated.

Gap buffers are not efficient for large files. For more information, see [the Wikipedia article](https://en.wikipedia.org/wiki/Gap_buffer).
