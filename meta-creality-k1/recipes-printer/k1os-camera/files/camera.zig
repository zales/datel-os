//! The camera, for everyone who wants its pictures as they are: the MJPEG
//! stream and the snapshots that uStreamer used to serve, and the frames the
//! encoder turns into H.264.
//!
//! The camera is open only while someone needs it: an MJPEG client, the
//! encoder, or a snapshot within the last minute (a timelapse asks for one
//! per layer, and the camera's exposure must not start over each time).
//!
//! Capturing itself is k1os-stream's (C): the same code that reads the K1's
//! camera for the encoder.
const std = @import("std");
const linux = std.os.linux;

pub const max_streams = 4;
const frame_bytes = 2 * 1024 * 1024;
/// one multipart part: headers and a frame
const part_bytes = 768 * 1024;
const linger_ms = 60_000;
/// frames to let pass after opening, while the camera finds its exposure
const warmup_frames = 4;
const boundary = "boundarydonotcross";

// ---- k1os-stream.h ----

const Camera = opaque {};
extern fn k1os_camera_open(dev: [*:0]const u8, width: c_uint, height: c_uint, fps: c_uint) ?*Camera;
extern fn k1os_camera_fd(cam: *const Camera) c_int;
extern fn k1os_camera_frame(cam: *Camera, data: *[*]const u8, len: *usize) c_int;
extern fn k1os_camera_close(cam: ?*Camera) void;

// ---- libc ----

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 = 0 };
const poll_in = 0x1;
const poll_out = 0x4;
const Mutex = extern struct {
    storage: [40]u8 align(8) = @splat(0),
    fn lock(m: *Mutex) void {
        _ = pthread_mutex_lock(m);
    }
    fn unlock(m: *Mutex) void {
        _ = pthread_mutex_unlock(m);
    }
};
extern fn pthread_mutex_lock(m: *Mutex) c_int;
extern fn pthread_mutex_unlock(m: *Mutex) c_int;
extern fn poll(fds: [*]PollFd, count: c_ulong, timeout_ms: c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn usleep(usec: c_uint) c_int;
extern fn dprintf(fd: c_int, fmt: [*:0]const u8, ...) c_int;
extern fn __errno_location() *c_int;

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// ---- settings ----

pub const Settings = struct {
    device: [64:0]u8 = @splat(0),
    width: u32 = 1280,
    height: u32 = 720,
    fps: u32 = 8,
};

/// Asked every time the camera is opened, so that a changed setting applies
/// without a restart. False when there is no camera to open.
pub var settings: *const fn (*Settings) bool = undefined;
/// Does anyone beside the clients here need frames (the encoder)?
pub var needed_elsewhere: *const fn () bool = undefined;

// ---- the newest frame ----

/// Guards `frame`, `frame_len`, `frame_seq` and `frame_ms`.
var frame_mutex: Mutex = .{};
var frame: [frame_bytes]u8 = undefined;
var frame_len: usize = 0;
/// counts frames since the camera was opened; 0 while it is closed
var frame_seq: u32 = 0;
var frame_ms: i64 = 0;
var frames_total = std.atomic.Value(u32).init(0);
var is_open = std.atomic.Value(bool).init(false);
/// the clock's low 32 bits at the last snapshot request
var snapshot_asked_ms = std.atomic.Value(u32).init(0);
var snapshot_asked = std.atomic.Value(bool).init(false);

fn clock32() u32 {
    return @truncate(@as(u64, @intCast(nowMs())));
}

/// The newest frame, copied into `out`. Opens the camera when it is closed
/// and waits for it; null after five seconds without a frame, or when the
/// frame does not fit.
pub fn snapshot(out: []u8) ?[]u8 {
    snapshot_asked_ms.store(clock32(), .seq_cst);
    snapshot_asked.store(true, .seq_cst);
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 20) {
        frame_mutex.lock();
        const fresh = frame_seq > warmup_frames and nowMs() - frame_ms < 2000;
        if (fresh) {
            defer frame_mutex.unlock();
            if (frame_len > out.len) return null;
            @memcpy(out[0..frame_len], frame[0..frame_len]);
            return out[0..frame_len];
        }
        frame_mutex.unlock();
        _ = usleep(20_000);
    }
    return null;
}

// The encoder takes its frames here (k1os_stream_hooks.frame and
// frame_done). The frame stays locked while the encoder copies it.

var encoder_seq: u32 = 0;

pub fn hookFrame(_: ?*anyopaque, data: *[*]const u8, len: *usize) callconv(.c) c_int {
    frame_mutex.lock();
    if (frame_seq == 0 or frame_seq == encoder_seq or frame_len == 0) {
        frame_mutex.unlock();
        return 0;
    }
    encoder_seq = frame_seq;
    data.* = &frame;
    len.* = frame_len;
    return 1;
}

pub fn hookDone(_: ?*anyopaque) callconv(.c) void {
    frame_mutex.unlock();
}

// ---- MJPEG clients ----

const Stream = struct {
    fd: c_int = -1,
    /// what of the current part has not been sent yet
    pending: usize = 0,
    sent: usize = 0,
};

/// Guards `streams` and their buffers.
var streams_mutex: Mutex = .{};
var streams: [max_streams]Stream = @splat(.{});
var parts: [max_streams][part_bytes]u8 = undefined;

fn streamCount() u32 {
    var n: u32 = 0;
    streams_mutex.lock();
    for (streams) |s| {
        if (s.fd >= 0) n += 1;
    }
    streams_mutex.unlock();
    return n;
}

/// Takes over a client's socket and sends it every frame from now on, as
/// "multipart/x-mixed-replace". False when all places are taken; the socket
/// then stays the caller's.
pub fn addStream(fd: c_int) bool {
    const head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=" ++ boundary ++ "\r\n" ++
        "Cache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
    streams_mutex.lock();
    defer streams_mutex.unlock();
    for (&streams, 0..) |*s, i| {
        if (s.fd >= 0) continue;
        const nonblock: c_int = @bitCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
        _ = fcntl(fd, linux.F.SETFL, nonblock);
        @memcpy(parts[i][0..head.len], head);
        s.* = .{ .fd = fd, .pending = head.len };
        return true;
    }
    return false;
}

/// Sends what a client still has pending, as far as its socket takes it.
fn flush(s: *Stream, part: []const u8) void {
    while (s.sent < s.pending) {
        const n = write(s.fd, part.ptr + s.sent, s.pending - s.sent);
        if (n > 0) {
            s.sent += @intCast(n);
            continue;
        }
        if (n < 0 and __errno_location().* == @intFromEnum(linux.E.AGAIN)) return;
        _ = close(s.fd);
        s.* = .{};
        return;
    }
    s.pending = 0;
    s.sent = 0;
}

/// Gives every client the new frame, except those that have not taken the
/// previous one yet: a slow client sees fewer frames, never an old queue.
fn distribute(jpeg: []const u8) void {
    streams_mutex.lock();
    defer streams_mutex.unlock();
    for (&streams, 0..) |*s, i| {
        if (s.fd < 0) continue;
        if (s.pending == 0) {
            const head = std.fmt.bufPrint(&parts[i], "--" ++ boundary ++ "\r\nContent-Type: image/jpeg\r\nContent-Length: {d}\r\n\r\n", .{jpeg.len}) catch unreachable;
            if (head.len + jpeg.len + 2 <= part_bytes) {
                @memcpy(parts[i][head.len..][0..jpeg.len], jpeg);
                parts[i][head.len + jpeg.len ..][0..2].* = "\r\n".*;
                s.pending = head.len + jpeg.len + 2;
            }
        }
        flush(s, &parts[i]);
    }
}

fn flushAll() void {
    streams_mutex.lock();
    defer streams_mutex.unlock();
    for (&streams, 0..) |*s, i| {
        if (s.fd >= 0 and s.pending > 0) flush(s, &parts[i]);
    }
}

// ---- the camera thread ----

fn needed() bool {
    if (streamCount() > 0 or needed_elsewhere()) return true;
    return snapshot_asked.load(.seq_cst) and clock32() -% snapshot_asked_ms.load(.seq_cst) < linger_ms;
}

pub const Status = struct { open: bool, frames: u32, streams: u32 };

pub fn status() Status {
    return .{ .open = is_open.load(.seq_cst), .frames = frames_total.load(.seq_cst), .streams = streamCount() };
}

pub fn task(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    var camera: ?*Camera = null;
    while (true) {
        if (!needed()) {
            if (camera) |cam| {
                k1os_camera_close(cam);
                camera = null;
                is_open.store(false, .seq_cst);
                frame_mutex.lock();
                frame_seq = 0;
                frame_len = 0;
                frame_mutex.unlock();
                _ = dprintf(2, "k1os-camera: camera closed\n");
            }
            _ = usleep(50_000);
            continue;
        }
        const cam = camera orelse opened: {
            var wanted: Settings = .{};
            const cam = if (settings(&wanted)) k1os_camera_open(&wanted.device, wanted.width, wanted.height, wanted.fps) else null;
            if (cam == null) {
                // no camera plugged in, or someone else has it
                _ = usleep(2_000_000);
                continue;
            }
            _ = dprintf(2, "k1os-camera: camera %s open, %ux%u at %u fps\n", @as([*:0]const u8, &wanted.device), wanted.width, wanted.height, wanted.fps);
            camera = cam;
            is_open.store(true, .seq_cst);
            break :opened cam.?;
        };

        var p = [1]PollFd{.{ .fd = k1os_camera_fd(cam), .events = poll_in }};
        _ = poll(&p, 1, 100);
        var data: [*]const u8 = undefined;
        var len: usize = 0;
        const got = k1os_camera_frame(cam, &data, &len);
        if (got < 0) {
            k1os_camera_close(cam);
            camera = null;
            is_open.store(false, .seq_cst);
            frame_mutex.lock();
            frame_seq = 0;
            frame_len = 0;
            frame_mutex.unlock();
            _ = dprintf(2, "k1os-camera: camera lost\n");
            _ = usleep(1_000_000);
            continue;
        }
        // the camera pads its frames with zeros behind the end marker
        while (got > 0 and len > 2 and data[len - 1] == 0) len -= 1;
        if (got > 0 and len <= frame_bytes) {
            frame_mutex.lock();
            @memcpy(frame[0..len], data[0..len]);
            frame_len = len;
            frame_seq +%= 1;
            if (frame_seq == 0) frame_seq = warmup_frames + 1;
            frame_ms = nowMs();
            frame_mutex.unlock();
            _ = frames_total.fetchAdd(1, .seq_cst);
            // only this thread writes `frame`, so it can read it unlocked
            distribute(frame[0..len]);
        } else flushAll();
    }
}
