const builtin = @import("builtin");
const std = @import("std.zig");
const Io = @This();
const fs = std.fs;
const assert = std.debug.assert;

pub const EventLoop = @import("Io/EventLoop.zig");

userdata: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// If it returns `null` it means `result` has been already populated and
    /// `await` will be a no-op.
    ///
    /// Thread-safe.
    @"async": *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The pointer of this slice is an "eager" result value.
        /// The length is the size in bytes of the result type.
        /// This pointer's lifetime expires directly after the call to this function.
        result: []u8,
        result_alignment: std.mem.Alignment,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*AnyFuture,
    /// Executes `start` asynchronously in a manner such that it cleans itself
    /// up. This mode does not support results, await, or cancel.
    ///
    /// Thread-safe.
    go: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) void,
    /// This function is only called when `async` returns a non-null value.
    ///
    /// Thread-safe.
    @"await": *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,
    /// Equivalent to `await` but initiates cancel request.
    ///
    /// This function is only called when `async` returns a non-null value.
    ///
    /// Thread-safe.
    cancel: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,
    /// Returns whether the current thread of execution is known to have
    /// been requested to cancel.
    ///
    /// Thread-safe.
    cancelRequested: *const fn (?*anyopaque) bool,

    mutexLock: *const fn (?*anyopaque, mutex: *Mutex) void,
    mutexUnlock: *const fn (?*anyopaque, mutex: *Mutex) void,

    conditionWait: *const fn (?*anyopaque, cond: *Condition, mutex: *Mutex, timeout_ns: ?u64) Condition.WaitError!void,
    conditionWake: *const fn (?*anyopaque, cond: *Condition, notify: Condition.Notify) void,

    createFile: *const fn (?*anyopaque, dir: fs.Dir, sub_path: []const u8, flags: fs.File.CreateFlags) FileOpenError!fs.File,
    openFile: *const fn (?*anyopaque, dir: fs.Dir, sub_path: []const u8, flags: fs.File.OpenFlags) FileOpenError!fs.File,
    closeFile: *const fn (?*anyopaque, fs.File) void,
    pread: *const fn (?*anyopaque, file: fs.File, buffer: []u8, offset: std.posix.off_t) FilePReadError!usize,
    pwrite: *const fn (?*anyopaque, file: fs.File, buffer: []const u8, offset: std.posix.off_t) FilePWriteError!usize,

    now: *const fn (?*anyopaque, clockid: std.posix.clockid_t) ClockGetTimeError!Timestamp,
    sleep: *const fn (?*anyopaque, clockid: std.posix.clockid_t, deadline: Deadline) SleepError!void,
};

pub const OpenFlags = fs.File.OpenFlags;
pub const CreateFlags = fs.File.CreateFlags;

pub const FileOpenError = fs.File.OpenError || error{Canceled};
pub const FileReadError = fs.File.ReadError || error{Canceled};
pub const FilePReadError = fs.File.PReadError || error{Canceled};
pub const FileWriteError = fs.File.WriteError || error{Canceled};
pub const FilePWriteError = fs.File.PWriteError || error{Canceled};

pub const Timestamp = enum(i96) {
    _,

    pub fn durationTo(from: Timestamp, to: Timestamp) i96 {
        return @intFromEnum(to) - @intFromEnum(from);
    }

    pub fn addDuration(from: Timestamp, duration: i96) Timestamp {
        return @enumFromInt(@intFromEnum(from) + duration);
    }
};
pub const Deadline = union(enum) {
    nanoseconds: i96,
    timestamp: Timestamp,
};
pub const ClockGetTimeError = std.posix.ClockGetTimeError || error{Canceled};
pub const SleepError = error{ UnsupportedClock, Unexpected, Canceled };

pub const AnyFuture = opaque {};

pub fn Future(Result: type) type {
    return struct {
        any_future: ?*AnyFuture,
        result: Result,

        /// Equivalent to `await` but sets a flag observable to application
        /// code that cancellation has been requested.
        ///
        /// Idempotent.
        pub fn cancel(f: *@This(), io: Io) Result {
            const any_future = f.any_future orelse return f.result;
            io.vtable.cancel(
                io.userdata,
                any_future,
                if (@sizeOf(Result) == 0) &.{} else @ptrCast((&f.result)[0..1]), // work around compiler bug
                .of(Result),
            );
            f.any_future = null;
            return f.result;
        }

        pub fn @"await"(f: *@This(), io: Io) Result {
            const any_future = f.any_future orelse return f.result;
            io.vtable.@"await"(
                io.userdata,
                any_future,
                if (@sizeOf(Result) == 0) &.{} else @ptrCast((&f.result)[0..1]), // work around compiler bug
                .of(Result),
            );
            f.any_future = null;
            return f.result;
        }
    };
}

pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(unlocked),

    pub const unlocked: u32 = 0b00;
    pub const locked: u32 = 0b01;
    pub const contended: u32 = 0b11; // must contain the `locked` bit for x86 optimization below

    pub fn tryLock(m: *Mutex) bool {
        // On x86, use `lock bts` instead of `lock cmpxchg` as:
        // - they both seem to mark the cache-line as modified regardless: https://stackoverflow.com/a/63350048
        // - `lock bts` is smaller instruction-wise which makes it better for inlining
        if (builtin.target.cpu.arch.isX86()) {
            const locked_bit = @ctz(locked);
            return m.state.bitSet(locked_bit, .acquire) == 0;
        }

        // Acquire barrier ensures grabbing the lock happens before the critical section
        // and that the previous lock holder's critical section happens before we grab the lock.
        return m.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) == null;
    }

    /// Avoids the vtable for uncontended locks.
    pub fn lock(m: *Mutex, io: Io) void {
        if (!m.tryLock()) {
            @branchHint(.unlikely);
            io.vtable.mutexLock(io.userdata, m);
        }
    }

    pub fn unlock(m: *Mutex, io: Io) void {
        io.vtable.mutexUnlock(io.userdata, m);
    }
};

pub const Condition = struct {
    state: u64 = 0,

    pub const WaitError = error{
        Timeout,
        Canceled,
    };

    /// How many waiters to wake up.
    pub const Notify = enum {
        one,
        all,
    };

    pub fn wait(cond: *Condition, io: Io, mutex: *Mutex) void {
        io.vtable.conditionWait(io.userdata, cond, mutex, null) catch |err| switch (err) {
            error.Timeout => unreachable, // no timeout provided so we shouldn't have timed-out
            error.Canceled => return, // handled as spurious wakeup
        };
    }

    pub fn timedWait(cond: *Condition, io: Io, mutex: *Mutex, timeout_ns: u64) WaitError!void {
        return io.vtable.conditionWait(io.userdata, cond, mutex, timeout_ns);
    }

    pub fn signal(cond: *Condition, io: Io) void {
        io.vtable.conditionWake(io.userdata, cond, .one);
    }

    pub fn broadcast(cond: *Condition, io: Io) void {
        io.vtable.conditionWake(io.userdata, cond, .all);
    }
};

pub const TypeErasedQueue = struct {
    mutex: Mutex,

    /// Ring buffer. This data is logically *after* queued getters.
    buffer: []u8,
    put_index: usize,
    get_index: usize,

    putters: std.DoublyLinkedList(PutNode),
    getters: std.DoublyLinkedList(GetNode),

    const PutNode = struct {
        remaining: []const u8,
        condition: Condition,
    };

    const GetNode = struct {
        remaining: []u8,
        condition: Condition,
    };

    pub fn init(buffer: []u8) TypeErasedQueue {
        return .{
            .mutex = .{},
            .buffer = buffer,
            .put_index = 0,
            .get_index = 0,
            .putters = .{},
            .getters = .{},
        };
    }

    pub fn put(q: *TypeErasedQueue, io: Io, elements: []const u8, min: usize) usize {
        assert(elements.len >= min);

        q.mutex.lock(io);
        defer q.mutex.unlock(io);

        // Getters have first priority on the data, and only when the getters
        // queue is empty do we start populating the buffer.

        var remaining = elements;
        while (true) {
            const getter = q.getters.popFirst() orelse break;
            const copy_len = @min(getter.data.remaining.len, remaining.len);
            @memcpy(getter.data.remaining[0..copy_len], remaining[0..copy_len]);
            remaining = remaining[copy_len..];
            getter.data.remaining = getter.data.remaining[copy_len..];
            if (getter.data.remaining.len == 0) {
                getter.data.condition.signal(io);
                continue;
            }
            q.getters.prepend(getter);
            assert(remaining.len == 0);
            return elements.len;
        }

        while (true) {
            {
                const available = q.buffer[q.put_index..];
                const copy_len = @min(available.len, remaining.len);
                @memcpy(available[0..copy_len], remaining[0..copy_len]);
                remaining = remaining[copy_len..];
                q.put_index += copy_len;
                if (remaining.len == 0) return elements.len;
            }
            {
                const available = q.buffer[0..q.get_index];
                const copy_len = @min(available.len, remaining.len);
                @memcpy(available[0..copy_len], remaining[0..copy_len]);
                remaining = remaining[copy_len..];
                q.put_index = copy_len;
                if (remaining.len == 0) return elements.len;
            }

            const total_filled = elements.len - remaining.len;
            if (total_filled >= min) return total_filled;

            var node: std.DoublyLinkedList(PutNode).Node = .{
                .data = .{ .remaining = remaining, .condition = .{} },
            };
            q.putters.append(&node);
            node.data.condition.wait(io, &q.mutex);
            remaining = node.data.remaining;
        }
    }

    pub fn get(q: *@This(), io: Io, buffer: []u8, min: usize) usize {
        assert(buffer.len >= min);

        q.mutex.lock(io);
        defer q.mutex.unlock(io);

        // The ring buffer gets first priority, then data should come from any
        // queued putters, then finally the ring buffer should be filled with
        // data from putters so they can be resumed.

        var remaining = buffer;
        while (true) {
            if (q.get_index <= q.put_index) {
                const available = q.buffer[q.get_index..q.put_index];
                const copy_len = @min(available.len, remaining.len);
                @memcpy(remaining[0..copy_len], available[0..copy_len]);
                q.get_index += copy_len;
                remaining = remaining[copy_len..];
                if (remaining.len == 0) return fillRingBufferFromPutters(q, io, buffer.len);
            } else {
                {
                    const available = q.buffer[q.get_index..];
                    const copy_len = @min(available.len, remaining.len);
                    @memcpy(remaining[0..copy_len], available[0..copy_len]);
                    q.get_index += copy_len;
                    remaining = remaining[copy_len..];
                    if (remaining.len == 0) return fillRingBufferFromPutters(q, io, buffer.len);
                }
                {
                    const available = q.buffer[0..q.put_index];
                    const copy_len = @min(available.len, remaining.len);
                    @memcpy(remaining[0..copy_len], available[0..copy_len]);
                    q.get_index = copy_len;
                    remaining = remaining[copy_len..];
                    if (remaining.len == 0) return fillRingBufferFromPutters(q, io, buffer.len);
                }
            }
            // Copy directly from putters into buffer.
            while (remaining.len > 0) {
                const putter = q.putters.popFirst() orelse break;
                const copy_len = @min(putter.data.remaining.len, remaining.len);
                @memcpy(remaining[0..copy_len], putter.data.remaining[0..copy_len]);
                putter.data.remaining = putter.data.remaining[copy_len..];
                remaining = remaining[copy_len..];
                if (putter.data.remaining.len == 0) {
                    putter.data.condition.signal(io);
                } else {
                    assert(remaining.len == 0);
                    q.putters.prepend(putter);
                    return fillRingBufferFromPutters(q, io, buffer.len);
                }
            }
            // Both ring buffer and putters queue is empty.
            const total_filled = buffer.len - remaining.len;
            if (total_filled >= min) return total_filled;

            var node: std.DoublyLinkedList(GetNode).Node = .{
                .data = .{ .remaining = remaining, .condition = .{} },
            };
            q.getters.append(&node);
            node.data.condition.wait(io, &q.mutex);
            remaining = node.data.remaining;
        }
    }

    /// Called when there is nonzero space available in the ring buffer and
    /// potentially putters waiting. The mutex is already held and the task is
    /// to copy putter data to the ring buffer and signal any putters whose
    /// buffers been fully copied.
    fn fillRingBufferFromPutters(q: *TypeErasedQueue, io: Io, len: usize) usize {
        while (true) {
            const putter = q.putters.popFirst() orelse return len;
            const available = q.buffer[q.put_index..];
            const copy_len = @min(available.len, putter.data.remaining.len);
            @memcpy(available[0..copy_len], putter.data.remaining[0..copy_len]);
            putter.data.remaining = putter.data.remaining[copy_len..];
            q.put_index += copy_len;
            if (putter.data.remaining.len == 0) {
                putter.data.condition.signal(io);
                continue;
            }
            const second_available = q.buffer[0..q.get_index];
            const second_copy_len = @min(second_available.len, putter.data.remaining.len);
            @memcpy(second_available[0..second_copy_len], putter.data.remaining[0..second_copy_len]);
            putter.data.remaining = putter.data.remaining[copy_len..];
            q.put_index = copy_len;
            if (putter.data.remaining.len == 0) {
                putter.data.condition.signal(io);
                continue;
            }
            q.putters.prepend(putter);
            return len;
        }
    }
};

/// Many producer, many consumer, thread-safe, runtime configurable buffer size.
/// When buffer is empty, consumers suspend and are resumed by producers.
/// When buffer is full, producers suspend and are resumed by consumers.
pub fn Queue(Elem: type) type {
    return struct {
        type_erased: TypeErasedQueue,

        pub fn init(buffer: []Elem) @This() {
            return .{ .type_erased = .init(@ptrCast(buffer)) };
        }

        /// Appends elements to the end of the queue. The function returns when
        /// at least `min` elements have been added to the buffer or sent
        /// directly to a consumer.
        ///
        /// Returns how many elements have been added to the queue.
        ///
        /// Asserts that `elements.len >= min`.
        pub fn put(q: *@This(), io: Io, elements: []const Elem, min: usize) usize {
            return @divExact(q.type_erased.put(io, @ptrCast(elements), min * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Receives elements from the beginning of the queue. The function
        /// returns when at least `min` elements have been populated inside
        /// `buffer`.
        ///
        /// Returns how many elements of `buffer` have been populated.
        ///
        /// Asserts that `buffer.len >= min`.
        pub fn get(q: *@This(), io: Io, buffer: []Elem, min: usize) usize {
            return @divExact(q.type_erased.get(io, @ptrCast(buffer), min * @sizeOf(Elem)), @sizeOf(Elem));
        }

        pub fn putOne(q: *@This(), io: Io, item: Elem) void {
            assert(q.put(io, &.{item}, 1) == 1);
        }

        pub fn getOne(q: *@This(), io: Io) Elem {
            var buf: [1]Elem = undefined;
            assert(q.get(io, &buf, 1) == 1);
            return buf[0];
        }
    };
}

/// Calls `function` with `args`, such that the return value of the function is
/// not guaranteed to be available until `await` is called.
pub fn @"async"(io: Io, function: anytype, args: anytype) Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @alignCast(@ptrCast(context));
            const result_casted: *Result = @ptrCast(@alignCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    var future: Future(Result) = undefined;
    future.any_future = io.vtable.@"async"(
        io.userdata,
        if (@sizeOf(Result) == 0) &.{} else @ptrCast((&future.result)[0..1]), // work around compiler bug
        .of(Result),
        if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]), // work around compiler bug
        .of(Args),
        TypeErased.start,
    );
    return future;
}

/// Calls `function` with `args` asynchronously. The resource cleans itself up
/// when the function returns. Does not support await, cancel, or a return value.
pub fn go(io: Io, function: anytype, args: anytype) void {
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque) void {
            const args_casted: *const Args = @alignCast(@ptrCast(context));
            @call(.auto, function, args_casted.*);
        }
    };
    io.vtable.go(
        io.userdata,
        if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]), // work around compiler bug
        .of(Args),
        TypeErased.start,
    );
}

pub fn openFile(io: Io, dir: fs.Dir, sub_path: []const u8, flags: fs.File.OpenFlags) FileOpenError!fs.File {
    return io.vtable.openFile(io.userdata, dir, sub_path, flags);
}

pub fn createFile(io: Io, dir: fs.Dir, sub_path: []const u8, flags: fs.File.CreateFlags) FileOpenError!fs.File {
    return io.vtable.createFile(io.userdata, dir, sub_path, flags);
}

pub fn closeFile(io: Io, file: fs.File) void {
    return io.vtable.closeFile(io.userdata, file);
}

pub fn read(io: Io, file: fs.File, buffer: []u8) FileReadError!usize {
    return @errorCast(io.pread(file, buffer, -1));
}

pub fn pread(io: Io, file: fs.File, buffer: []u8, offset: std.posix.off_t) FilePReadError!usize {
    return io.vtable.pread(io.userdata, file, buffer, offset);
}

pub fn write(io: Io, file: fs.File, buffer: []const u8) FileWriteError!usize {
    return @errorCast(io.pwrite(file, buffer, -1));
}

pub fn pwrite(io: Io, file: fs.File, buffer: []const u8, offset: std.posix.off_t) FilePWriteError!usize {
    return io.vtable.pwrite(io.userdata, file, buffer, offset);
}

pub fn writeAll(io: Io, file: fs.File, bytes: []const u8) FileWriteError!void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try io.write(file, bytes[index..]);
    }
}

pub fn readAll(io: Io, file: fs.File, buffer: []u8) FileReadError!usize {
    var index: usize = 0;
    while (index != buffer.len) {
        const amt = try io.read(file, buffer[index..]);
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

pub fn now(io: Io, clockid: std.posix.clockid_t) ClockGetTimeError!Timestamp {
    return io.vtable.now(io.userdata, clockid);
}

pub fn sleep(io: Io, clockid: std.posix.clockid_t, deadline: Deadline) SleepError!void {
    return io.vtable.sleep(io.userdata, clockid, deadline);
}
