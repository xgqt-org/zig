const std = @import("std.zig");
const Io = @This();
const fs = std.fs;

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

pub const FileOpenError = fs.File.OpenError || error{AsyncCancel};
pub const FileReadError = fs.File.ReadError || error{AsyncCancel};
pub const FilePReadError = fs.File.PReadError || error{AsyncCancel};
pub const FileWriteError = fs.File.WriteError || error{AsyncCancel};
pub const FilePWriteError = fs.File.PWriteError || error{AsyncCancel};

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
pub const ClockGetTimeError = std.posix.ClockGetTimeError || error{AsyncCancel};
pub const SleepError = error{ UnsupportedClock, Unexpected, AsyncCancel };

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
            io.vtable.cancel(io.userdata, any_future, @ptrCast((&f.result)[0..1]), .of(Result));
            f.any_future = null;
            return f.result;
        }

        pub fn @"await"(f: *@This(), io: Io) Result {
            const any_future = f.any_future orelse return f.result;
            io.vtable.@"await"(io.userdata, any_future, @ptrCast((&f.result)[0..1]), .of(Result));
            f.any_future = null;
            return f.result;
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
        @ptrCast((&future.result)[0..1]),
        .of(Result),
        if (@sizeOf(Args) == 0) &.{} else @ptrCast((&args)[0..1]), // work around compiler bug
        .of(Args),
        TypeErased.start,
    );
    return future;
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
