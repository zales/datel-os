//! Publishes the pictures to an RTMP server such as Twitch's ingest, with a
//! silent audio track beside them (Twitch wants one).
//!
//! The pictures arrive from the thread that reads the encoder (push) and go
//! out from a thread of their own, with a queue in between: a slow uplink
//! must not hold up the viewers on the local network. When the queue is full
//! everything in it is dropped and sending resumes at the next key picture,
//! which shows as a short freeze instead of a stream that falls behind.
const std = @import("std");
const linux = std.os.linux;
const rtmp = @import("rtmp.zig");

const queue_bytes = 3 * 1024 * 1024;
const io_timeout_ms = 10_000;
const retry_ms = 5_000;
const chunk_size = 4096;
/// chunk streams, as other publishers number them
const cs_control = 2;
const cs_command = 3;
const cs_audio = 4;
const cs_video = 6;

// ---- libc ----

const SockaddrIn = extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 };
/// struct addrinfo as Linux lays it out
const AddrInfo = extern struct {
    flags: c_int = 0,
    family: c_int = 0,
    socktype: c_int = 0,
    protocol: c_int = 0,
    addrlen: u32 = 0,
    addr: ?*SockaddrIn = null,
    canonname: ?[*:0]u8 = null,
    next: ?*AddrInfo = null,
};
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
extern fn getaddrinfo(node: [*:0]const u8, service: [*:0]const u8, hints: *const AddrInfo, result: *?*AddrInfo) c_int;
extern fn freeaddrinfo(list: *AddrInfo) void;
extern fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern fn connect(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
extern fn getsockopt(fd: c_int, level: c_int, name: c_int, value: *anyopaque, len: *u32) c_int;
extern fn poll(fds: [*]PollFd, count: c_ulong, timeout_ms: c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn usleep(usec: c_uint) c_int;
extern fn dprintf(fd: c_int, fmt: [*:0]const u8, ...) c_int;

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// ---- the queue between the two threads ----

/// Pictures in arrival order, each behind a small header, in one buffer.
const Queue = struct {
    const Header = extern struct { len: u32, key: u32, ms: i64 };
    buf: []u8,
    start: usize = 0,
    end: usize = 0,
    /// set after an overflow: nothing is taken until a key picture comes
    need_key: bool = true,
    dropped: u32 = 0,

    fn clear(q: *Queue) void {
        q.start = 0;
        q.end = 0;
        q.need_key = true;
    }

    fn push(q: *Queue, picture: []const u8, key: bool, ms: i64) void {
        if (q.need_key and !key) return;
        const size = @sizeOf(Header) + picture.len;
        if (q.buf.len - q.end < size and q.start > 0) {
            std.mem.copyForwards(u8, q.buf[0 .. q.end - q.start], q.buf[q.start..q.end]);
            q.end -= q.start;
            q.start = 0;
        }
        if (q.buf.len - q.end < size) {
            q.clear();
            q.dropped += 1;
            if (!key or q.buf.len < size) return;
        }
        q.need_key = false;
        const header: Header = .{ .len = @intCast(picture.len), .key = @intFromBool(key), .ms = ms };
        @memcpy(q.buf[q.end..][0..@sizeOf(Header)], std.mem.asBytes(&header));
        @memcpy(q.buf[q.end + @sizeOf(Header) ..][0..picture.len], picture);
        q.end += size;
    }

    /// Copies the oldest picture into `out`.
    fn pop(q: *Queue, out: []u8) ?struct { picture: []u8, key: bool, ms: i64 } {
        if (q.start == q.end) return null;
        var header: Header = undefined;
        @memcpy(std.mem.asBytes(&header), q.buf[q.start..][0..@sizeOf(Header)]);
        const at = q.start + @sizeOf(Header);
        q.start = at + header.len;
        if (q.start == q.end) {
            q.start = 0;
            q.end = 0;
        }
        if (header.len > out.len) return null;
        @memcpy(out[0..header.len], q.buf[at..][0..header.len]);
        return .{ .picture = out[0..header.len], .key = header.key != 0, .ms = header.ms };
    }
};

// ---- what the other threads see ----

pub const State = enum(u8) { off, connecting, live, waiting };

var mutex: Mutex = .{};
var queue_storage: [queue_bytes]u8 = undefined;
var queue: Queue = .{ .buf = &queue_storage };
var url_buf: [300]u8 = undefined;
var url_len: usize = 0;
var key_buf: [200]u8 = undefined;
var key_len: usize = 0;
var enabled = std.atomic.Value(bool).init(false);
/// changes with every start, so that a session notices a new target
var generation = std.atomic.Value(u32).init(0);
var state = std.atomic.Value(State).init(.off);
var pictures_published = std.atomic.Value(u32).init(0);

/// Publishing to `url` ("rtmp://host[:port]/app") with stream key `key`
/// from now on, until stop(). False when either is unusable.
pub fn start(url: []const u8, key: []const u8) bool {
    if (rtmp.Url.parse(url) == null or url.len > url_buf.len) return false;
    if (key.len == 0 or key.len > key_buf.len) return false;
    for (key) |ch| {
        if (ch <= ' ' or ch >= 0x7f) return false;
    }
    mutex.lock();
    @memcpy(url_buf[0..url.len], url);
    url_len = url.len;
    @memcpy(key_buf[0..key.len], key);
    key_len = key.len;
    queue.clear();
    mutex.unlock();
    _ = generation.fetchAdd(1, .seq_cst);
    enabled.store(true, .seq_cst);
    return true;
}

pub fn stop() void {
    enabled.store(false, .seq_cst);
}

/// Does the encoder have to run for us?
pub fn active() bool {
    return enabled.load(.seq_cst);
}

pub fn push(picture: []const u8, key: bool, ms: i64) void {
    if (state.load(.seq_cst) != .live) return;
    mutex.lock();
    queue.push(picture, key, ms);
    mutex.unlock();
}

/// Is the stream waiting for a key picture to start, or to start again?
pub fn needsKeyPicture() bool {
    if (state.load(.seq_cst) != .live) return false;
    mutex.lock();
    defer mutex.unlock();
    return queue.need_key;
}

pub const Status = struct { state: State, pictures: u32, overflows: u32 };

pub fn status() Status {
    mutex.lock();
    const overflows = queue.dropped;
    mutex.unlock();
    return .{ .state = state.load(.seq_cst), .pictures = pictures_published.load(.seq_cst), .overflows = overflows };
}

// ---- one connection ----

const Socket = struct {
    fd: c_int,

    pub fn write(s: *Socket, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            var p = [1]PollFd{.{ .fd = s.fd, .events = poll_out }};
            if (poll(&p, 1, io_timeout_ms) <= 0) return error.Timeout;
            const n = write_(s.fd, bytes.ptr + sent, bytes.len - sent);
            if (n < 0) return error.ConnectionLost;
            sent += @intCast(n);
        }
    }

    pub fn readExact(s: *Socket, out: []u8) !void {
        var have: usize = 0;
        while (have < out.len) {
            var p = [1]PollFd{.{ .fd = s.fd, .events = poll_in }};
            if (poll(&p, 1, io_timeout_ms) <= 0) return error.Timeout;
            const n = read(s.fd, out[have..].ptr, out.len - have);
            if (n <= 0) return error.ConnectionLost;
            have += @intCast(n);
        }
    }

    fn readable(s: *Socket) bool {
        var p = [1]PollFd{.{ .fd = s.fd, .events = poll_in }};
        return poll(&p, 1, 0) > 0;
    }
};
const write_ = write;

fn connectTcp(host: []const u8, port: u16) !c_int {
    var host_z: [256]u8 = undefined;
    var port_z: [8]u8 = undefined;
    const node: [*:0]const u8 = @ptrCast((try std.fmt.bufPrint(&host_z, "{s}\x00", .{host})).ptr);
    const service: [*:0]const u8 = @ptrCast((try std.fmt.bufPrint(&port_z, "{d}\x00", .{port})).ptr);
    const hints: AddrInfo = .{ .family = linux.AF.INET, .socktype = linux.SOCK.STREAM };
    var list: ?*AddrInfo = null;
    if (getaddrinfo(node, service, &hints, &list) != 0) return error.UnknownHost;
    const first = list orelse return error.UnknownHost;
    defer freeaddrinfo(first);
    const addr = first.addr orelse return error.UnknownHost;

    const fd = socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (fd < 0) return error.NoSocket;
    errdefer _ = close(fd);
    // Not blocking, so that neither the connect nor a stalled uplink can hold
    // this thread longer than io_timeout_ms.
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    _ = fcntl(fd, linux.F.SETFL, nonblock);
    _ = connect(fd, addr, @sizeOf(SockaddrIn));
    var p = [1]PollFd{.{ .fd = fd, .events = poll_out }};
    if (poll(&p, 1, io_timeout_ms) <= 0) return error.Timeout;
    var failure: c_int = 0;
    var len: u32 = @sizeOf(c_int);
    if (getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, &failure, &len) != 0 or failure != 0) return error.ConnectionRefused;
    return fd;
}

const Session = struct {
    socket: Socket,
    reader: rtmp.Reader(*Socket),
    stream_id: u32 = 0,

    fn send(s: *Session, chunk_stream: u6, kind: rtmp.MessageType, stream_id: u32, timestamp: u32, payload: []const u8) !void {
        try rtmp.writeMessage(&s.socket, chunk_size, chunk_stream, kind, stream_id, timestamp, payload);
    }

    /// Reads until the reply to command `transaction` arrives.
    fn result(s: *Session, transaction: f64) !rtmp.Command {
        while (true) {
            const message = try s.reader.next();
            if (message.kind != .command_amf0) continue;
            const command = rtmp.Command.parse(message.payload) orelse continue;
            if (command.transaction != transaction) continue;
            if (std.mem.eql(u8, command.name, "_result")) return command;
            if (std.mem.eql(u8, command.name, "_error")) return error.Refused;
        }
    }

    /// Answers what the server asks while we send: a ping wants a pong.
    fn serveIncoming(s: *Session) !void {
        while (s.socket.readable()) {
            const message = try s.reader.next();
            switch (message.kind) {
                .user_control => if (message.payload.len >= 6 and std.mem.readInt(u16, message.payload[0..2], .big) == 6) {
                    const pong = [_]u8{ 0, 7 } ++ message.payload[2..6].*;
                    try s.send(cs_control, .user_control, 0, 0, &pong);
                },
                .command_amf0 => if (std.mem.find(u8, message.payload, "NetStream.Publish.") != null and
                    std.mem.find(u8, message.payload, "NetStream.Publish.Start") == null) return error.PublishEnded,
                else => {},
            }
        }
    }

    fn handshake(s: *Session) !void {
        // C0 and C1: version 3, a timestamp, zero, random bytes
        var ours: [1 + rtmp.handshake_len]u8 = undefined;
        @memset(ours[0..9], 0);
        ours[0] = 3;
        const urandom = open("/dev/urandom", 0);
        if (urandom < 0 or read(urandom, ours[9..].ptr, ours.len - 9) < 0) return error.NoRandom;
        _ = close(urandom);
        try s.socket.write(&ours);
        // S0, S1 and S2; C2 is S1 sent back
        var theirs: [1 + 2 * rtmp.handshake_len]u8 = undefined;
        try s.socket.readExact(&theirs);
        if (theirs[0] != 3) return error.NotRtmp;
        try s.socket.write(theirs[1..][0..rtmp.handshake_len]);
    }

    fn open_(s: *Session, url: rtmp.Url, url_text: []const u8, key: []const u8) !void {
        var buf: [1024]u8 = undefined;
        try s.handshake();
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, chunk_size, .big);
        try s.send(cs_control, .set_chunk_size, 0, 0, &size);

        var a: rtmp.Amf = .{ .buf = &buf };
        a.string("connect");
        a.number(1);
        a.objectStart();
        a.stringField("app", url.app);
        a.stringField("type", "nonprivate");
        a.stringField("flashVer", "FMLE/3.0 (compatible; k1os-camera)");
        a.stringField("tcUrl", url_text);
        a.objectEnd();
        try s.send(cs_command, .command_amf0, 0, 0, a.bytes());
        _ = try s.result(1);

        inline for (.{ "releaseStream", "FCPublish" }, .{ 2, 3 }) |name, transaction| {
            a = .{ .buf = &buf };
            a.string(name);
            a.number(transaction);
            a.null_();
            a.string(key);
            try s.send(cs_command, .command_amf0, 0, 0, a.bytes());
        }
        a = .{ .buf = &buf };
        a.string("createStream");
        a.number(4);
        a.null_();
        try s.send(cs_command, .command_amf0, 0, 0, a.bytes());
        const id = (try s.result(4)).numberAfterNull() orelse return error.NoStream;
        if (id < 1 or id > 0xffff) return error.NoStream;
        s.stream_id = @intFromFloat(id);

        a = .{ .buf = &buf };
        a.string("publish");
        a.number(5);
        a.null_();
        a.string(key);
        a.string("live");
        try s.send(cs_command, .command_amf0, s.stream_id, 0, a.bytes());
        // the server says how it went in an onStatus command
        while (true) {
            const message = try s.reader.next();
            if (message.kind != .command_amf0) continue;
            if (std.mem.find(u8, message.payload, "NetStream.Publish.Start") != null) break;
            if (std.mem.find(u8, message.payload, "onStatus") != null) return error.PublishRefused;
        }

        a = .{ .buf = &buf };
        a.string("@setDataFrame");
        a.string("onMetaData");
        a.arrayStart();
        a.numberField("videocodecid", 7); // AVC
        a.numberField("audiocodecid", 10); // AAC
        a.numberField("audiosamplerate", rtmp.aac_sample_rate);
        a.numberField("audiosamplesize", 16);
        a.booleanField("stereo", false);
        a.stringField("encoder", "k1os-camera");
        a.objectEnd();
        try s.send(cs_command, .data_amf0, s.stream_id, 0, a.bytes());
    }

    /// Tells the server that the stream is over, so that the channel goes
    /// offline at once instead of after its timeout.
    fn close_(s: *Session, key: []const u8) void {
        var buf: [512]u8 = undefined;
        var a: rtmp.Amf = .{ .buf = &buf };
        a.string("FCUnpublish");
        a.number(6);
        a.null_();
        a.string(key);
        s.send(cs_command, .command_amf0, 0, 0, a.bytes()) catch return;
        a = .{ .buf = &buf };
        a.string("deleteStream");
        a.number(7);
        a.null_();
        a.number(@floatFromInt(s.stream_id));
        s.send(cs_command, .command_amf0, 0, 0, a.bytes()) catch return;
        // let the two commands leave before the socket closes
        _ = usleep(300_000);
    }
};

var picture_buf: [1024 * 1024]u8 = undefined;
var message_buf: [1024 * 1024 + 4096]u8 = undefined;

fn run(this_generation: u32) !void {
    var url_copy: [300]u8 = undefined;
    var key_copy: [200]u8 = undefined;
    mutex.lock();
    @memcpy(url_copy[0..url_len], url_buf[0..url_len]);
    @memcpy(key_copy[0..key_len], key_buf[0..key_len]);
    const url_text = url_copy[0..url_len];
    const key = key_copy[0..key_len];
    mutex.unlock();
    const url = rtmp.Url.parse(url_text) orelse return error.BadUrl;

    state.store(.connecting, .seq_cst);
    var session: Session = .{ .socket = .{ .fd = try connectTcp(url.host, url.port) }, .reader = undefined };
    session.reader = .{ .source = &session.socket };
    defer _ = close(session.socket.fd);
    try session.open_(url, url_text, key);
    _ = dprintf(2, "k1os-camera: publishing to %.*s\n", @as(c_int, @intCast(url.host.len)), url.host.ptr);

    mutex.lock();
    queue.clear();
    mutex.unlock();
    state.store(.live, .seq_cst);
    defer session.close_(key);

    var base_ms: ?i64 = null;
    var audio_frames: u64 = 0;
    var last_picture_ms = nowMs();
    while (enabled.load(.seq_cst) and generation.load(.seq_cst) == this_generation) {
        try session.serveIncoming();
        mutex.lock();
        const popped = queue.pop(&picture_buf);
        mutex.unlock();
        const item = popped orelse {
            // the encoder starts when the stream does, so give it time
            if (nowMs() - last_picture_ms > 30_000) return error.NoPictures;
            _ = usleep(5_000);
            continue;
        };
        last_picture_ms = nowMs();

        if (base_ms == null) {
            // The stream opens with the two configurations, taken from the
            // first key picture; the queue hands out nothing before one.
            const sets = rtmp.parameterSets(item.picture) orelse continue;
            const config = rtmp.videoConfig(sets.sps, sets.pps, &message_buf) orelse continue;
            try session.send(cs_video, .video, session.stream_id, 0, config);
            try session.send(cs_audio, .audio, session.stream_id, 0, &(.{ rtmp.audio_tag, 0 } ++ rtmp.aac_config));
            base_ms = item.ms;
        }
        const timestamp: u32 = @truncate(@as(u64, @intCast(@max(0, item.ms - base_ms.?))));

        // silence up to this picture's time, one AAC frame per 1024 samples
        while (audio_frames * rtmp.aac_frame_samples * 1000 / rtmp.aac_sample_rate <= timestamp) : (audio_frames += 1) {
            const audio_time: u32 = @intCast(audio_frames * rtmp.aac_frame_samples * 1000 / rtmp.aac_sample_rate);
            try session.send(cs_audio, .audio, session.stream_id, audio_time, &(.{ rtmp.audio_tag, 1 } ++ rtmp.aac_silence));
        }
        const frame = rtmp.videoFrame(item.picture, item.key, &message_buf) orelse continue;
        try session.send(cs_video, .video, session.stream_id, timestamp, frame);
        _ = pictures_published.fetchAdd(1, .seq_cst);
    }
}

/// The publishing thread: connects while publishing is wanted, and again
/// after a failure.
pub fn task(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (true) {
        if (!enabled.load(.seq_cst)) {
            state.store(.off, .seq_cst);
            _ = usleep(100_000);
            continue;
        }
        const this_generation = generation.load(.seq_cst);
        run(this_generation) catch |failure| {
            _ = dprintf(2, "k1os-camera: publishing failed: %s\n", @errorName(failure).ptr);
            state.store(.waiting, .seq_cst);
            var waited: u32 = 0;
            while (waited < retry_ms and enabled.load(.seq_cst) and generation.load(.seq_cst) == this_generation) : (waited += 100) _ = usleep(100_000);
            continue;
        };
        _ = dprintf(2, "k1os-camera: publishing ended\n");
    }
}

// ---- tests ----

test "Queue hands pictures out in order and starts at a key picture" {
    var storage: [200]u8 = undefined;
    var q: Queue = .{ .buf = &storage };
    var out: [64]u8 = undefined;
    q.push("delta", false, 1); // nothing before a key picture
    try std.testing.expectEqual(null, q.pop(&out));
    q.push("KEY", true, 2);
    q.push("d1", false, 3);
    const first = q.pop(&out).?;
    try std.testing.expectEqualStrings("KEY", first.picture);
    try std.testing.expect(first.key);
    try std.testing.expectEqual(2, first.ms);
    const second = q.pop(&out).?;
    try std.testing.expectEqualStrings("d1", second.picture);
    try std.testing.expect(!second.key);
    try std.testing.expectEqual(null, q.pop(&out));
}

test "Queue makes room by moving, and on overflow drops all and waits for a key picture" {
    var storage: [100]u8 = undefined;
    var q: Queue = .{ .buf = &storage };
    var out: [64]u8 = undefined;
    const twenty: [20]u8 = @splat('x');
    q.push(&twenty, true, 1); // 36 bytes with the header
    q.push(&twenty, false, 2);
    _ = q.pop(&out).?; // frees the front
    q.push(&twenty, false, 3); // fits only after moving the rest forward
    try std.testing.expectEqual(0, q.dropped);
    try std.testing.expectEqual(2, q.pop(&out).?.ms);
    try std.testing.expectEqual(3, q.pop(&out).?.ms);

    q.push(&twenty, true, 4);
    q.push(&twenty, false, 5);
    q.push(&twenty, false, 6); // full: 4 and 5 go, 6 is no key picture
    try std.testing.expectEqual(1, q.dropped);
    try std.testing.expectEqual(null, q.pop(&out));
    q.push(&twenty, false, 7);
    try std.testing.expectEqual(null, q.pop(&out));
    q.push(&twenty, true, 8);
    try std.testing.expectEqual(8, q.pop(&out).?.ms);
    // a picture larger than the whole queue
    const huge: [200]u8 = @splat('y');
    q.push(&huge, true, 9);
    try std.testing.expectEqual(null, q.pop(&out));
}

test "start refuses unusable targets" {
    try std.testing.expect(!start("http://example.org/app", "key"));
    try std.testing.expect(!start("rtmp://live.twitch.tv/app", ""));
    try std.testing.expect(!start("rtmp://live.twitch.tv/app", "has space"));
    try std.testing.expect(!active());
}
