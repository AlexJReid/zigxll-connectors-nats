// Window buffer — fixed-size ring buffer of f64 values, keyed by NATS subject.
//
// Used by NATS.SUBWIN (RTD) and NATS.SUBWIN_VALS (UDF) to accumulate
// the last N numeric messages on a subject and expose them as a spill array.

const std = @import("std");

const allocator = std.heap.c_allocator;

pub const max_window_size = 4096;

pub const WindowBuffer = struct {
    subject: []const u8, // owned copy
    capacity: u32,
    buf: []f64, // owned, length = capacity
    head: u32 = 0, // next write position
    count: u32 = 0, // how many slots are filled (≤ capacity)
    generation: u64 = 0,

    pub fn init(subject: []const u8, capacity: u32) !WindowBuffer {
        const cap = @min(capacity, max_window_size);
        const buf = try allocator.alloc(f64, cap);
        const subj = try allocator.dupe(u8, subject);
        return .{
            .subject = subj,
            .capacity = cap,
            .buf = buf,
        };
    }

    pub fn deinit(self: *WindowBuffer) void {
        allocator.free(self.buf);
        allocator.free(self.subject);
    }

    pub fn push(self: *WindowBuffer, value: f64) void {
        self.buf[self.head] = value;
        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
        self.generation +%= 1;
    }

    /// Return values oldest-first as a freshly allocated slice. Caller must free.
    /// Returns a zero-length allocated slice if empty.
    pub fn snapshot(self: *const WindowBuffer) ![]f64 {
        if (self.count == 0) {
            return try allocator.alloc(f64, 0);
        }
        const out = try allocator.alloc(f64, self.count);
        if (self.count < self.capacity) {
            // Buffer hasn't wrapped yet — data is 0..count
            @memcpy(out, self.buf[0..self.count]);
        } else {
            // Wrapped — oldest is at head, read head..cap then 0..head
            const tail_len = self.capacity - self.head;
            @memcpy(out[0..tail_len], self.buf[self.head..self.capacity]);
            @memcpy(out[tail_len..], self.buf[0..self.head]);
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Global registry: subject -> WindowBuffer
// Protected by a mutex since onMsg fires from nats.c threads while
// NATS.SUBWIN_VALS runs on Excel's calc thread.
// ---------------------------------------------------------------------------

var mu: std.Thread.Mutex = .{};
var buffers: std.StringHashMap(WindowBuffer) = std.StringHashMap(WindowBuffer).init(allocator);

/// Get or create a window buffer for `subject` with the given capacity.
/// If a buffer already exists for this subject, returns it (ignoring capacity).
pub fn getOrCreate(subject: []const u8, capacity: u32) !*WindowBuffer {
    mu.lock();
    defer mu.unlock();

    if (buffers.getPtr(subject)) |wb| return wb;

    var wb = try WindowBuffer.init(subject, capacity);
    errdefer wb.deinit();
    // The key in the map points into wb.subject (owned by the buffer).
    try buffers.put(wb.subject, wb);
    return buffers.getPtr(wb.subject).?;
}

/// Push a value and return the new generation. Thread-safe.
pub fn pushValue(subject: []const u8, value: f64) ?u64 {
    mu.lock();
    defer mu.unlock();
    if (buffers.getPtr(subject)) |wb| {
        wb.push(value);
        return wb.generation;
    }
    return null;
}

/// Take a snapshot of the buffer. Thread-safe. Caller must free the returned slice.
pub fn snapshotOf(subject: []const u8) !?[]f64 {
    mu.lock();
    defer mu.unlock();
    if (buffers.getPtr(subject)) |wb| {
        return try wb.snapshot();
    }
    return null;
}

/// Get the current generation for a subject. Returns 0 if not found.
pub fn generation(subject: []const u8) u64 {
    mu.lock();
    defer mu.unlock();
    if (buffers.getPtr(subject)) |w| return w.generation;
    return 0;
}

/// Remove and destroy a buffer. Called on disconnect.
pub fn remove(subject: []const u8) void {
    mu.lock();
    defer mu.unlock();
    if (buffers.fetchRemove(subject)) |kv| {
        var wb = kv.value;
        wb.deinit();
    }
}

/// Destroy all buffers. Called on terminate.
pub fn deinitAll() void {
    mu.lock();
    defer mu.unlock();
    var it = buffers.iterator();
    while (it.next()) |entry| {
        var wb = entry.value_ptr;
        wb.deinit();
    }
    buffers.clearAndFree();
}
