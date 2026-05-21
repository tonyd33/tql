const overlay_map = @import("ds/overlay_map.zig");
const rc = @import("ds/rc.zig");
const ring_buffer = @import("ds/ring_buffer.zig");
const thread_safe = @import("ds/thread_safe.zig");
const blocking_queue = @import("ds/blocking_queue.zig");

pub const OverlayMap = overlay_map.OverlayMap;
pub const Rc = rc.Rc;
pub const RingBuffer = ring_buffer.RingBuffer;
pub const ThreadSafe = thread_safe.ThreadSafe;
pub const BlockingQueue = blocking_queue.BlockingQueue;

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(overlay_map);
    refAllDecls(rc);
    refAllDecls(ring_buffer);
    refAllDecls(thread_safe);
    refAllDecls(blocking_queue);
}
