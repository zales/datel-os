//! k1os-camera: the K1's camera as WebRTC, for several viewers at once.
//!
//!   k1os-camera [<address>:]<port> helix:<command>
//!   k1os-camera [<address>:]<port> <command>
//!
//! HTTP is served on that port, on one address (127.0.0.1 behind nginx) or
//! on all of them.
//!
//! With "helix:" this program has the camera itself (camera.zig) and the
//! pictures come from the encoder built in, k1os-stream (C, linked in): the
//! status overlay and H.264 on the K1's hardware codec. The command prints
//! options, one per line: k1os-stream's, and for the camera --camera-device,
//! --camera-size WxH and --camera-fps.
//! Without it, the command itself writes raw H.264 (Annex B) to its stdout,
//! which is how this program runs on machines without the codec.
//! Either way the pictures are made only while anyone watches.
//!
//!   POST /webrtc       camera-streamer's signaling, which Mainsail speaks:
//!                      {"type":"request"} is answered with an SDP offer and an
//!                      id, and the browser posts {"type":"answer"}.
//!   GET /stream.h264   the same pictures as a plain byte stream (for ffmpeg)
//!   GET /status        viewer counts as JSON
//!   GET /?action=stream    the camera's own JPEG frames as an MJPEG stream,
//!   GET /?action=snapshot  and the newest one; also /stream and /snapshot.
//!                          The addresses uStreamer had; only with "helix:".
//!   POST /publish      {"url":"rtmp://host/app","key":"..."}: also send the
//!                      pictures to an RTMP server such as Twitch (publish.zig)
//!   POST /unpublish    stop that
//!                      Both only from this machine: they redirect the stream.
//!   GET /              a test page
//!
//! How a viewer gets its video:
//!
//!   1. The offer names one UDP port of ours and says we are an ICE-lite
//!      agent: we only answer connectivity checks (stun.zig). The browser
//!      finds the way; its own candidates are never needed, so the
//!      {"type":"remote_candidate"} posts are accepted and ignored.
//!   2. The first valid check tells us the browser's address. We start a DTLS
//!      handshake with it (dtls.c, on mbedtls) and compare its certificate
//!      with the fingerprint in the answer.
//!   3. The handshake yields the SRTP keys. Pictures are cut into RTP packets
//!      (rtp.zig), encrypted (srtp.zig) and sent; the last packets are kept
//!      and sent again when the browser reports them lost.
//!   4. The browser keeps checking the path every few seconds. When that
//!      stops, or it closes the DTLS connection, the viewer is gone.
const std = @import("std");
const linux = std.os.linux;
const stun = @import("stun.zig");
const srtp = @import("srtp.zig");
const rtp = @import("rtp.zig");
const publish = @import("publish.zig");
const camera = @import("camera.zig");

/// Zig's software AES by default reads its whole lookup table for every byte,
/// so that a process sharing the CPU cannot learn key bits from cache timing.
/// On the K1 that cost 29 % of a core for one viewer. Plain table lookups,
/// which is also what libsrtp and mbedtls do, bring it down; nothing else on
/// the printer runs code of people who are not allowed to see its camera.
pub const std_options: std.Options = .{ .side_channels_mitigations = .none };

/// Slots, including viewers that are still connecting or have gone silent.
const max_viewers = 4;
/// How many viewers get the video at once. Each one costs the CPU its own
/// encryption and the Wi-Fi its own 2.5 Mbit/s; a third is turned away.
const max_watching = 2;
/// A connected viewer that has not been heard from for this long (a closed
/// or reloaded tab) no longer counts and may be replaced.
const stale_ms = 7_000;
/// Lost packets are sent again, but only up to this share of what is sent
/// anyway: one for every `resend_share` packets, saved up to `resend_burst`.
/// A viewer on a link that loses more does not get to double the traffic
/// for everybody; it asks for a key picture instead.
const resend_share = 4;
const resend_burst = 96;
const max_raw = 2;
const connect_timeout_ms = 30_000;
/// Chrome checks consent every five seconds or so (RFC 7675).
const silence_timeout_ms = 20_000;
const payload_type = 96;
const fingerprint_len = 95;

// ---- dtls.c ----

const Dtls = opaque {};
extern fn dtls_global_init(fingerprint: *[fingerprint_len + 1]u8) c_int;
extern fn dtls_new(user: ?*anyopaque) ?*Dtls;
extern fn dtls_free(d: ?*Dtls) void;
extern fn dtls_step(d: *Dtls, in: ?[*]const u8, len: usize) c_int;
extern fn dtls_result(d: *Dtls, keys: *[60]u8, fingerprint: *[fingerprint_len + 1]u8) void;

// ---- k1os-stream.h ----

const Iovec = extern struct { base: [*]const u8, len: usize };
const StreamHooks = extern struct {
    jpeg_fd: c_int,
    picture: *const fn (?*anyopaque, [*]const Iovec, c_int) callconv(.c) c_int,
    ctx: ?*anyopaque = null,
    frame: ?*const fn (?*anyopaque, *[*]const u8, *usize) callconv(.c) c_int = null,
    frame_done: ?*const fn (?*anyopaque) callconv(.c) void = null,
};
extern fn k1os_stream_run(argc: c_int, argv: [*]const ?[*:0]u8, hooks: *const StreamHooks) c_int;
extern fn k1os_stream_stop() void;
extern fn k1os_stream_key_picture() void;

// ---- libc ----

const SockaddrIn = extern struct {
    family: u16 = linux.AF.INET,
    port: u16 = 0,
    addr: [4]u8 = @splat(0),
    zero: [8]u8 = @splat(0),
};
const PollFd = extern struct { fd: c_int, events: i16, revents: i16 = 0 };
const poll_in = 0x1;
const poll_out = 0x4;
/// pthread_mutex_t is 24 bytes on 32-bit MIPS (musl and glibc); all zeros is unlocked.
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
extern fn pthread_create(thread: *c_ulong, attr: ?*anyopaque, start: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) c_int;
extern fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
extern fn bind(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
extern fn connect(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
extern fn getsockname(fd: c_int, addr: *SockaddrIn, len: *u32) c_int;
extern fn listen(fd: c_int, backlog: c_int) c_int;
extern fn accept(fd: c_int, addr: ?*SockaddrIn, len: ?*u32) c_int;
extern fn sendto(fd: c_int, buf: [*]const u8, len: usize, flags: c_int, addr: *const SockaddrIn, addr_len: u32) isize;
extern fn recvfrom(fd: c_int, buf: [*]u8, len: usize, flags: c_int, addr: *SockaddrIn, addr_len: *u32) isize;
extern fn poll(fds: [*]PollFd, count: c_ulong, timeout_ms: c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn pipe(fds: *[2]c_int) c_int;
extern fn fork() c_int;
extern fn dup2(old: c_int, new: c_int) c_int;
extern fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern fn _exit(code: c_int) noreturn;
extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern fn usleep(usec: c_uint) c_int;
extern fn signal(sig: c_int, handler: usize) usize;
extern fn dprintf(fd: c_int, fmt: [*:0]const u8, ...) c_int;

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn setNonBlocking(fd: c_int) void {
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    _ = fcntl(fd, linux.F.SETFL, nonblock);
}

fn randomBytes(out: []u8) void {
    const fd = open("/dev/urandom", 0);
    if (fd < 0 or read(fd, out.ptr, out.len) != @as(isize, @intCast(out.len))) {
        _ = dprintf(2, "k1os-camera: no random numbers\n");
        _exit(1);
    }
    _ = close(fd);
}

/// Letters and digits, as ICE wants its credentials (RFC 8839 5.4).
fn randomText(out: []u8) void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    randomBytes(out);
    for (out) |*ch| ch.* = alphabet[ch.* % alphabet.len];
}

// ---- parsing what clients send ----

fn isIpv4(text: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| : (parts += 1) {
        if (part.len == 0 or part.len > 3) return false;
        _ = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return parts == 4;
}


fn parseIpv4(text: []const u8) ?[4]u8 {
    if (!isIpv4(text)) return null;
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    for (&out) |*byte| byte.* = std.fmt.parseInt(u8, it.next().?, 10) catch unreachable;
    return out;
}

/// The certificate fingerprint in the browser's SDP answer, the one thing
/// that is needed from it.
fn answerFingerprint(sdp: []const u8) ?[fingerprint_len]u8 {
    const name = "a=fingerprint:sha-256 ";
    const at = std.ascii.findIgnoreCase(sdp, name) orelse return null;
    const rest = sdp[at + name.len ..];
    if (rest.len < fingerprint_len) return null;
    var out: [fingerprint_len]u8 = undefined;
    for (rest[0..fingerprint_len], &out, 0..) |ch, *o, i| {
        const ok = if (i % 3 == 2) ch == ':' else std.ascii.isHex(ch);
        if (!ok) return null;
        o.* = std.ascii.toUpper(ch);
    }
    return out;
}

/// The value of the string member `key` found at or after `from.*` in `json`,
/// unescaped into `out`; `from.*` then points behind it. A key is only taken
/// where a colon follows it, so the same word as a value does not match.
fn jsonString(json: []const u8, comptime key: []const u8, from: *usize, out: []u8) ?[]u8 {
    const quoted = "\"" ++ key ++ "\"";
    var at = from.*;
    while (std.mem.findPos(u8, json, at, quoted)) |found| {
        at = found + quoted.len;
        var i = at;
        while (i < json.len and std.ascii.isWhitespace(json[i])) i += 1;
        if (i == json.len or json[i] != ':') continue;
        i += 1;
        while (i < json.len and std.ascii.isWhitespace(json[i])) i += 1;
        if (i == json.len or json[i] != '"') continue;
        i += 1;
        var n: usize = 0;
        while (i < json.len and json[i] != '"') : (i += 1) {
            var ch = json[i];
            if (ch == '\\') {
                i += 1;
                if (i == json.len) return null;
                ch = switch (json[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'b' => 0x08,
                    'f' => 0x0c,
                    'u' => unicode: {
                        if (i + 4 >= json.len) return null;
                        const code = std.fmt.parseInt(u16, json[i + 1 .. i + 5], 16) catch return null;
                        i += 4;
                        break :unicode if (code < 0x80) @as(u8, @intCast(code)) else '?';
                    },
                    else => json[i],
                };
            }
            if (n == out.len) return null;
            out[n] = ch;
            n += 1;
        }
        if (i == json.len) return null;
        from.* = i + 1;
        return out[0..n];
    }
    return null;
}

/// `text` as the inside of a JSON string.
fn jsonEscape(text: []const u8, out: []u8) ?[]u8 {
    var n: usize = 0;
    for (text) |ch| {
        const piece: []const u8 = switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            else => if (ch < 0x20) continue else &.{ch},
        };
        if (n + piece.len > out.len) return null;
        @memcpy(out[n..][0..piece.len], piece);
        n += piece.len;
    }
    return out[0..n];
}

const pictureEnd = rtp.pictureEnd;
const isKeyPicture = rtp.isKeyPicture;

// ---- viewers ----

const Phase = enum {
    /// has our offer
    offered,
    /// sent its answer; waiting for its first connectivity check
    answered,
    handshaking,
    connected,
};

const Viewer = struct {
    active: bool = false,
    id: u64 = 0,
    phase: Phase = .offered,
    fd: c_int = -1,
    ufrag: [8]u8 = undefined,
    pwd: [24]u8 = undefined,
    /// where its valid connectivity checks come from
    peer: ?SockaddrIn = null,
    /// what the answer says its certificate is
    fingerprint: [fingerprint_len]u8 = undefined,
    dtls: ?*Dtls = null,
    rtp_out: srtp.Context = undefined,
    rtcp_in: srtp.Context = undefined,
    ssrc: u32 = 0,
    seq: u16 = 0,
    /// how often `seq` has wrapped; part of the SRTP packet index
    roc: u32 = 0,
    timestamp_base: u32 = 0,
    born_ms: i64 = 0,
    last_check_ms: i64 = 0,
    /// has been sent a key picture, so the following ones make sense to it
    live: bool = false,
    /// how many lost packets it may still be sent again
    resend_credit: u16 = 0,

    fn drop(v: *Viewer, why: [*:0]const u8) void {
        if (!v.active) return;
        _ = dprintf(2, "k1os-camera: viewer %08x gone (%s)\n", @as(c_uint, @truncate(v.id)), why);
        dtls_free(v.dtls);
        _ = close(v.fd);
        v.* = .{};
    }

    fn send(v: *const Viewer, datagram: []const u8) bool {
        const peer = v.peer orelse return false;
        // The socket does not block: when its buffer is full (a slow Wi-Fi
        // link), the packet is lost here and the browser asks for it again.
        return sendto(v.fd, datagram.ptr, datagram.len, 0, &peer, @sizeOf(SockaddrIn)) >= 0;
    }

    fn onStun(v: *Viewer, message: []const u8, from: SockaddrIn, now: i64) void {
        const check = stun.parseBindingRequest(message, &v.ufrag, &v.pwd) orelse return;
        v.last_check_ms = now;
        if (v.peer == null or check.use_candidate) v.peer = from;
        var response: [stun.response_len]u8 = undefined;
        stun.bindingResponse(check, from.addr, std.mem.bigToNative(u16, from.port), &v.pwd, &response);
        _ = sendto(v.fd, &response, response.len, 0, &from, @sizeOf(SockaddrIn));
    }

    /// Feeds the handshake a datagram, or none to let it start or resend.
    fn stepDtls(v: *Viewer, datagram: ?[]const u8) void {
        const d = v.dtls orelse return;
        const result = if (datagram) |in| dtls_step(d, in.ptr, in.len) else dtls_step(d, null, 0);
        if (result < 0) return v.drop(if (v.phase == .connected) "closed" else "handshake failed");
        if (result == 0 or v.phase == .connected) return;

        var keys: [60]u8 = undefined;
        var theirs: [fingerprint_len + 1]u8 = undefined;
        dtls_result(d, &keys, &theirs);
        if (!std.mem.eql(u8, theirs[0..fingerprint_len], &v.fingerprint)) return v.drop("certificate does not match the answer");
        // client key, server key, client salt, server salt; we are the client
        v.rtp_out = .init(keys[0..16].*, keys[32..46].*, .rtp);
        v.rtcp_in = .init(keys[16..32].*, keys[46..60].*, .rtcp);
        if (watchingViewers(nowMs()) >= max_watching) return v.drop("too many viewers");
        v.phase = .connected;
        requestKeyPicture();
        _ = dprintf(2, "k1os-camera: viewer %08x connected after %d ms\n", @as(c_uint, @truncate(v.id)), @as(c_int, @intCast(nowMs() - v.born_ms)));
    }

    fn onRtcp(v: *Viewer, datagram: []u8) void {
        if (v.phase != .connected) return;
        const report = v.rtcp_in.unprotectRtcp(datagram) orelse return;
        if (rtp.asksForKeyPicture(report)) requestKeyPicture();
        var lost: [64]u16 = undefined;
        for (rtp.nackedPackets(report, &lost)) |seq| {
            const again = resendOf(v).find(seq) orelse continue;
            if (v.resend_credit == 0) {
                _ = resends_refused.fetchAdd(1, .seq_cst);
                continue;
            }
            v.resend_credit -= 1;
            if (v.send(again)) _ = packets_resent.fetchAdd(1, .seq_cst);
        }
    }

    /// Reads what has arrived on the viewer's port. What a datagram is shows
    /// in its first byte (RFC 7983).
    fn receive(v: *Viewer, now: i64) void {
        var buf: [1500]u8 = undefined;
        var budget: usize = 64;
        while (v.active and budget > 0) : (budget -= 1) {
            var from: SockaddrIn = .{};
            var from_len: u32 = @sizeOf(SockaddrIn);
            const n = recvfrom(v.fd, &buf, buf.len, 0, &from, &from_len);
            if (n <= 0) return;
            const datagram = buf[0..@intCast(n)];
            if (stun.isStun(datagram)) {
                v.onStun(datagram, from, now);
            } else if (datagram[0] >= 20 and datagram[0] <= 63) {
                v.stepDtls(datagram);
            } else if (rtp.isRtcp(datagram)) {
                v.onRtcp(datagram);
            }
        }
    }

    fn tick(v: *Viewer, now: i64) void {
        switch (v.phase) {
            .offered => {},
            .answered => if (v.peer != null) {
                v.dtls = dtls_new(v) orelse return v.drop("out of memory");
                v.phase = .handshaking;
                v.stepDtls(null);
            },
            .handshaking => v.stepDtls(null),
            .connected => if (now - v.last_check_ms > silence_timeout_ms) return v.drop("silent"),
        }
        if (v.active and v.phase != .connected and now - v.born_ms > connect_timeout_ms) v.drop("never connected");
    }

    fn sendPicture(v: *Viewer, picture: []const u8, clock: u32) void {
        var packets = rtp.Packetizer.init(picture);
        while (packets.next()) |payload| {
            var buf: [rtp.header_len + rtp.max_payload + srtp.rtp_overhead]u8 = undefined;
            rtp.writeHeader(buf[0..rtp.header_len], payload_type, payload.marker, v.seq, clock +% v.timestamp_base, v.ssrc);
            var len: usize = rtp.header_len;
            @memcpy(buf[len..][0..payload.prefix_len], payload.prefix[0..payload.prefix_len]);
            len += payload.prefix_len;
            @memcpy(buf[len..][0..payload.body.len], payload.body);
            len += payload.body.len;
            const packet = buf[0..v.rtp_out.protectRtp(&buf, len, v.roc)];
            _ = v.send(packet);
            resendOf(v).store(packet);
            if (v.seq % resend_share == 0 and v.resend_credit < resend_burst) v.resend_credit += 1;
            v.seq +%= 1;
            if (v.seq == 0) v.roc += 1;
        }
    }
};

/// Guards `viewers`, `resend` and the DTLS state behind them.
var lock: Mutex = .{};
var viewers: [max_viewers]Viewer = @splat(.{});
/// resend[i] belongs to viewers[i]
var resend: [max_viewers]rtp.Resend = @splat(.{});
var packets_resent = std.atomic.Value(u32).init(0);
var resends_refused = std.atomic.Value(u32).init(0);
var pictures_sent = std.atomic.Value(u32).init(0);
/// of the certificate every viewer is shown
var our_fingerprint: [fingerprint_len + 1]u8 = undefined;

const Raw = struct { fd: c_int = -1, live: bool = false };
var raw_lock: Mutex = .{};
var raw: [max_raw]Raw = @splat(.{});

var source_cmd: [*:0]const u8 = undefined;
/// pictures come from the built-in encoder, not from a command's output
var helix_mode = false;
var encoder_running = std.atomic.Value(bool).init(false);
/// the clock's low 32 bits: MIPS32 has no 64-bit atomics
var last_key_request_ms = std.atomic.Value(u32).init(0);

/// Asks the encoder to make its next picture a key picture: a viewer has
/// just joined or has lost one, and the next regular one may be two seconds
/// away. Not more than twice a second, whoever asks.
fn requestKeyPicture() void {
    if (!helix_mode) return;
    const now: u32 = @truncate(@as(u64, @intCast(nowMs())));
    if (now -% last_key_request_ms.load(.seq_cst) < 500) return;
    last_key_request_ms.store(now, .seq_cst);
    k1os_stream_key_picture();
}

fn resendOf(v: *const Viewer) *rtp.Resend {
    return &resend[(@intFromPtr(v) - @intFromPtr(&viewers)) / @sizeOf(Viewer)];
}

/// dtls.c sends its handshake datagrams through this.
export fn camera_dtls_send(user: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const v: *Viewer = @ptrCast(@alignCast(user.?));
    return if (v.send(data[0..len])) 0 else -1;
}

fn connectedViewers() u32 {
    var n: u32 = 0;
    for (viewers) |v| {
        if (v.active and v.phase == .connected) n += 1;
    }
    return n;
}

fn rawReaders() u32 {
    var n: u32 = 0;
    raw_lock.lock();
    for (raw) |r| {
        if (r.fd >= 0) n += 1;
    }
    raw_lock.unlock();
    return n;
}

/// A free slot; failing that, the oldest viewer that never connected.
/// Connected viewers that are being heard from.
fn watchingViewers(now: i64) usize {
    var n: usize = 0;
    for (viewers) |v| {
        if (v.active and v.phase == .connected and now - v.last_check_ms <= stale_ms) n += 1;
    }
    return n;
}

fn freeViewer() ?*Viewer {
    const now = nowMs();
    if (watchingViewers(now) >= max_watching) return null;
    // room for a new one: a silent viewer goes first
    for (&viewers) |*v| {
        if (v.active and v.phase == .connected and now - v.last_check_ms > stale_ms) v.drop("silent, replaced");
    }
    var oldest: ?*Viewer = null;
    for (&viewers) |*v| {
        if (!v.active) return v;
        if (v.phase == .connected) continue;
        if (oldest == null or v.born_ms < oldest.?.born_ms) oldest = v;
    }
    if (oldest) |v| v.drop("slot reused");
    return oldest;
}

fn findViewer(id: u64) ?*Viewer {
    for (&viewers) |*v| {
        if (v.active and v.id == id) return v;
    }
    return null;
}

/// Our address as the host at `client` sees it: the one the kernel would
/// send from. Connecting a UDP socket sends nothing.
fn localAddressFor(client: [4]u8) ?[4]u8 {
    const fd = socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    const to: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, 9), .addr = client };
    var local: SockaddrIn = .{};
    var len: u32 = @sizeOf(SockaddrIn);
    if (connect(fd, &to, @sizeOf(SockaddrIn)) != 0 or getsockname(fd, &local, &len) != 0) return null;
    return local.addr;
}

/// Sets up a viewer with its own UDP port and writes the SDP offer for it.
fn newViewer(client: [4]u8, sdp_out: []u8) ?struct { id: u64, sdp: []u8 } {
    const address = localAddressFor(client) orelse return null;
    const v = freeViewer() orelse return null;
    const fd = socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (fd < 0) return null;
    var bound: SockaddrIn = .{};
    var len: u32 = @sizeOf(SockaddrIn);
    if (bind(fd, &bound, @sizeOf(SockaddrIn)) != 0 or getsockname(fd, &bound, &len) != 0) {
        _ = close(fd);
        return null;
    }
    setNonBlocking(fd);

    var numbers: [18]u8 = undefined;
    randomBytes(&numbers);
    const now = nowMs();
    v.* = .{
        .active = true,
        .id = std.mem.readInt(u64, numbers[0..8], .little) | 1,
        .fd = fd,
        .ssrc = std.mem.readInt(u32, numbers[8..12], .little) | 1,
        // below 2^15, so that the first wrap is far away (RFC 3550 5.1)
        .seq = std.mem.readInt(u16, numbers[12..14], .little) >> 1,
        .timestamp_base = std.mem.readInt(u32, numbers[14..18], .little),
        .born_ms = now,
        .last_check_ms = now,
    };
    randomText(&v.ufrag);
    randomText(&v.pwd);
    resendOf(v).clear();

    const sdp = std.fmt.bufPrint(sdp_out, "v=0\r\n" ++
        "o=- {d} 2 IN IP4 127.0.0.1\r\n" ++
        "s=-\r\n" ++
        "t=0 0\r\n" ++
        "a=group:BUNDLE 0\r\n" ++
        "a=msid-semantic: WMS k1os-camera\r\n" ++
        "a=ice-lite\r\n" ++
        "m=video 9 UDP/TLS/RTP/SAVPF {d}\r\n" ++
        "c=IN IP4 0.0.0.0\r\n" ++
        "a=rtcp:9 IN IP4 0.0.0.0\r\n" ++
        "a=ice-ufrag:{s}\r\n" ++
        "a=ice-pwd:{s}\r\n" ++
        "a=fingerprint:sha-256 {s}\r\n" ++
        "a=setup:active\r\n" ++
        "a=mid:0\r\n" ++
        "a=sendonly\r\n" ++
        "a=rtcp-mux\r\n" ++
        "a=rtpmap:{d} H264/90000\r\n" ++
        "a=rtcp-fb:{d} nack\r\n" ++
        "a=rtcp-fb:{d} nack pli\r\n" ++
        "a=fmtp:{d} level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f\r\n" ++
        "a=msid:k1os-camera camera\r\n" ++
        "a=ssrc:{d} cname:k1os-camera\r\n" ++
        "a=candidate:1 1 udp 2130706431 {d}.{d}.{d}.{d} {d} typ host\r\n" ++
        "a=end-of-candidates\r\n", .{
        v.id >> 1,            payload_type, v.ufrag,      v.pwd,      our_fingerprint[0..fingerprint_len],
        payload_type,         payload_type, payload_type, payload_type, v.ssrc,
        address[0],           address[1],   address[2],   address[3],
        std.mem.bigToNative(u16, bound.port),
    }) catch {
        v.drop("offer does not fit");
        return null;
    };
    return .{ .id = v.id, .sdp = sdp };
}

/// Receives for every viewer, keeps handshakes moving and removes viewers
/// that left or never came.
fn loopTask(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    while (true) {
        var fds: [max_viewers]PollFd = undefined;
        var count: c_ulong = 0;
        lock.lock();
        for (viewers) |v| {
            if (!v.active) continue;
            fds[count] = .{ .fd = v.fd, .events = poll_in };
            count += 1;
        }
        lock.unlock();
        // 20 ms is also how often a handshake looks at its resend timer
        if (count == 0) _ = usleep(20_000) else _ = poll(&fds, count, 20);
        // The encoder runs in the main thread, which cannot look up while it
        // waits for the camera; the stop is repeated until it has ended.
        if (encoder_running.load(.seq_cst) and !wanted()) k1os_stream_stop();

        const now = nowMs();
        lock.lock();
        for (&viewers) |*v| {
            if (v.active) v.receive(now);
            if (v.active) v.tick(now);
        }
        lock.unlock();
    }
}

// ---- HTTP ----

/// Writes all of `data` unless the peer takes longer than `budget_ms`.
fn writeAll(fd: c_int, data: []const u8, budget_ms: c_int) bool {
    var sent: usize = 0;
    while (sent < data.len) {
        var p = [1]PollFd{.{ .fd = fd, .events = poll_out }};
        if (poll(&p, 1, budget_ms) <= 0) return false;
        const n = write(fd, data.ptr + sent, data.len - sent);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

fn reply(fd: c_int, status: []const u8, content_type: []const u8, body: []const u8) void {
    replyWith(fd, status, content_type, "", body);
}

/// `extra` is further header lines, each with its line end.
fn replyWith(fd: c_int, status: []const u8, content_type: []const u8, extra: []const u8, body: []const u8) void {
    var head: [320]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}" ++
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len, extra }) catch return;
    if (writeAll(fd, h, 5000)) _ = writeAll(fd, body, 5000);
}

fn headerValue(headers: []const u8, comptime name: []const u8) ?[]const u8 {
    const at = std.ascii.findIgnoreCase(headers, "\n" ++ name ++ ":") orelse return null;
    const rest = headers[at + name.len + 2 ..];
    const end = std.mem.findAny(u8, rest, "\r\n") orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " ");
}

/// The viewer's address: the socket's, or what nginx passes on from localhost.
fn clientIp(peer: SockaddrIn, headers: []const u8, out: *[16]u8) []const u8 {
    if (peer.addr[0] == 127) {
        inline for (.{ "X-Real-IP", "X-Forwarded-For" }) |name| {
            if (headerValue(headers, name)) |value| {
                const first = std.mem.trim(u8, value[0 .. std.mem.findScalar(u8, value, ',') orelse value.len], " ");
                if (isIpv4(first)) return first;
            }
        }
    }
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ peer.addr[0], peer.addr[1], peer.addr[2], peer.addr[3] }) catch unreachable;
}

fn signaling(fd: c_int, body: []const u8, client_ip: []const u8) void {
    var at: usize = 0;
    var type_buf: [32]u8 = undefined;
    const kind = jsonString(body, "type", &at, &type_buf) orelse return reply(fd, "400 Bad Request", "text/plain", "no type");

    if (std.mem.eql(u8, kind, "request")) {
        const client = parseIpv4(client_ip) orelse return reply(fd, "400 Bad Request", "text/plain", "IPv4 only");
        var sdp_buf: [1024]u8 = undefined;
        var escaped: [1280]u8 = undefined;
        var out: [1536]u8 = undefined;
        lock.lock();
        const made = newViewer(client, &sdp_buf);
        lock.unlock();
        const viewer = made orelse return reply(fd, "503 Service Unavailable", "text/plain", "no free viewer slot");
        // "iceServers" makes Mainsail post its candidates; it has no use for servers
        const text = std.fmt.bufPrint(&out, "{{\"type\":\"offer\",\"id\":\"{x:0>16}\",\"iceServers\":[],\"sdp\":\"{s}\"}}", .{ viewer.id, jsonEscape(viewer.sdp, &escaped).? }) catch unreachable;
        return reply(fd, "200 OK", "application/json", text);
    }

    var id_buf: [32]u8 = undefined;
    at = 0;
    const id_text = jsonString(body, "id", &at, &id_buf) orelse return reply(fd, "400 Bad Request", "text/plain", "no id");
    const id = std.fmt.parseInt(u64, id_text, 16) catch return reply(fd, "400 Bad Request", "text/plain", "bad id");

    if (std.mem.eql(u8, kind, "answer")) {
        var sdp_buf: [8192]u8 = undefined;
        at = 0;
        const sdp = jsonString(body, "sdp", &at, &sdp_buf) orelse return reply(fd, "400 Bad Request", "text/plain", "no sdp");
        const fingerprint = answerFingerprint(sdp) orelse return reply(fd, "400 Bad Request", "text/plain", "no sha-256 fingerprint");
        lock.lock();
        const found = findViewer(id);
        if (found) |v| {
            if (v.phase == .offered) {
                v.fingerprint = fingerprint;
                v.phase = .answered;
            }
        }
        lock.unlock();
        if (found == null) return reply(fd, "404 Not Found", "text/plain", "unknown id");
        return reply(fd, "200 OK", "application/json", "{}");
    }

    if (std.mem.eql(u8, kind, "remote_candidate")) {
        // An ICE-lite agent waits for the browser's checks; where they come
        // from is all it needs to know.
        lock.lock();
        const known = findViewer(id) != null;
        lock.unlock();
        if (!known) return reply(fd, "404 Not Found", "text/plain", "unknown id");
        return reply(fd, "200 OK", "application/json", "{}");
    }
    reply(fd, "400 Bad Request", "text/plain", "unknown type");
}

var request: [32768]u8 = undefined;
var snapshot_buf: [2 * 1024 * 1024]u8 = undefined;

/// "GET /?action=stream" as nginx passes on "/webcam/?action=stream", or
/// uStreamer's own "/stream"; the same for "snapshot".
fn wantsCamera(headers: []const u8, comptime what: []const u8) bool {
    const line = headers[0 .. std.mem.find(u8, headers, "\r\n") orelse return false];
    if (!std.mem.startsWith(u8, line, "GET /")) return false;
    const target = line[4 .. std.mem.findScalarPos(u8, line, 4, ' ') orelse return false];
    if (std.mem.eql(u8, target, "/" ++ what) or std.mem.startsWith(u8, target, "/" ++ what ++ "?")) return true;
    return std.mem.startsWith(u8, target, "/?") and std.mem.find(u8, target, "action=" ++ what) != null;
}

/// Serves one request. True when the socket was kept (a raw stream reader).
fn handle(fd: c_int, peer: SockaddrIn) bool {
    var have: usize = 0;
    var body_at: usize = 0;
    var want: usize = 0;
    while (have < request.len) {
        var p = [1]PollFd{.{ .fd = fd, .events = poll_in }};
        if (poll(&p, 1, 5000) <= 0) return false;
        const n = read(fd, request[have..].ptr, request.len - have);
        if (n <= 0) break;
        have += @intCast(n);
        if (body_at == 0) {
            const end = std.mem.find(u8, request[0..have], "\r\n\r\n") orelse continue;
            body_at = end + 4;
            const length = headerValue(request[0..end], "Content-Length") orelse "0";
            want = std.fmt.parseInt(usize, length, 10) catch return false;
        }
        if (have - body_at >= want) break;
    }
    if (body_at == 0 or have - body_at < want) return false;
    const headers = request[0..body_at];
    const body = request[body_at..][0..want];

    if (std.mem.startsWith(u8, headers, "POST /webrtc")) {
        var ip_buf: [16]u8 = undefined;
        signaling(fd, body, clientIp(peer, headers, &ip_buf));
    } else if (std.mem.startsWith(u8, headers, "GET /stream.h264 ")) {
        raw_lock.lock();
        defer raw_lock.unlock();
        for (&raw) |*r| {
            if (r.fd >= 0) continue;
            if (!writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: video/h264\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", 5000)) return false;
            setNonBlocking(fd);
            r.* = .{ .fd = fd };
            return true;
        }
        reply(fd, "503 Service Unavailable", "text/plain", "too many readers");
    } else if (std.mem.startsWith(u8, headers, "POST /publish ") or std.mem.startsWith(u8, headers, "POST /unpublish ")) {
        // nginx passes requests of others on from this machine and names them
        const local = peer.addr[0] == 127 and headerValue(headers, "X-Real-IP") == null and headerValue(headers, "X-Forwarded-For") == null;
        if (!local) {
            reply(fd, "403 Forbidden", "text/plain", "only from the printer itself");
        } else if (headers[6] == 'u') {
            publish.stop();
            reply(fd, "200 OK", "application/json", "{}");
        } else {
            var url_buf: [300]u8 = undefined;
            var key_buf: [200]u8 = undefined;
            var at: usize = 0;
            const url = jsonString(body, "url", &at, &url_buf);
            at = 0;
            const stream_key = jsonString(body, "key", &at, &key_buf);
            if (url != null and stream_key != null and publish.start(url.?, stream_key.?)) {
                reply(fd, "200 OK", "application/json", "{}");
            } else {
                reply(fd, "400 Bad Request", "text/plain", "needs \"url\" (rtmp://host[:port]/app) and \"key\"");
            }
        }
    } else if (helix_mode and wantsCamera(headers, "stream")) {
        if (camera.addStream(fd)) return true;
        reply(fd, "503 Service Unavailable", "text/plain", "too many streams");
    } else if (helix_mode and wantsCamera(headers, "snapshot")) {
        if (camera.snapshot(&snapshot_buf)) |jpeg| {
            // any page may show the pictures, as with uStreamer
            replyWith(fd, "200 OK", "image/jpeg", "Access-Control-Allow-Origin: *\r\n", jpeg);
        } else {
            reply(fd, "503 Service Unavailable", "text/plain", "no picture from the camera");
        }
    } else if (std.mem.startsWith(u8, headers, "GET /status ")) {
        var out: [384]u8 = undefined;
        lock.lock();
        var slots: u32 = 0;
        for (viewers) |v| {
            if (v.active) slots += 1;
        }
        const connected = connectedViewers();
        lock.unlock();
        const published = publish.status();
        const cam: camera.Status = if (helix_mode) camera.status() else .{ .open = false, .frames = 0, .streams = 0 };
        const text = std.fmt.bufPrint(&out, "{{\"viewers\":{d},\"connecting\":{d},\"readers\":{d},\"pictures\":{d},\"resent\":{d},\"resends_refused\":{d}," ++
            "\"publish\":\"{s}\",\"published\":{d},\"publish_overflows\":{d}," ++
            "\"camera\":{},\"camera_frames\":{d},\"mjpeg\":{d}}}\n", .{
            connected,                     slots - connected, rawReaders(),        pictures_sent.load(.seq_cst),
            packets_resent.load(.seq_cst), resends_refused.load(.seq_cst), @tagName(published.state), published.pictures, published.overflows,
            cam.open,                      cam.frames,        cam.streams,
        }) catch unreachable;
        reply(fd, "200 OK", "application/json", text);
    } else if (std.mem.startsWith(u8, headers, "GET / ")) {
        reply(fd, "200 OK", "text/html", page);
    } else {
        reply(fd, "404 Not Found", "text/plain", "");
    }
    return false;
}

fn httpTask(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const listener: *const c_int = @ptrCast(@alignCast(arg.?));
    while (true) {
        var peer: SockaddrIn = .{};
        var len: u32 = @sizeOf(SockaddrIn);
        const fd = accept(listener.*, &peer, &len);
        if (fd < 0) continue;
        if (!handle(fd, peer)) _ = close(fd);
    }
}

/// The test page signals the way Mainsail's camera-streamer client does.
const page =
    \\<!doctype html><meta charset=utf-8><title>k1os-camera</title>
    \\<video id=v autoplay muted playsinline style='width:640px;background:#000'></video>
    \\<pre id=s>connecting</pre><script>
    \\const post=b=>fetch('webrtc',{method:'POST',body:JSON.stringify(b)});
    \\(async()=>{const r=await post({type:'request',keepAlive:true});
    \\if(r.status!=200)throw new Error('request: '+r.status+' '+await r.text());
    \\const o=await r.json();const pc=new RTCPeerConnection({iceServers:o.iceServers});window.pc=pc;
    \\pc.addTransceiver('video',{direction:'recvonly'});
    \\pc.onicecandidate=e=>{if(e.candidate)post({id:o.id,type:'remote_candidate',candidates:[e.candidate]})};
    \\pc.ontrack=e=>{v.srcObject=e.streams[0]||new MediaStream([e.track])};
    \\await pc.setRemoteDescription(o);
    \\await pc.setLocalDescription(await pc.createAnswer());
    \\const a=await post({type:'answer',id:o.id,sdp:pc.localDescription.sdp});
    \\if(a.status!=200)throw new Error('answer: '+a.status+' '+await a.text());
    \\setInterval(async()=>{let t={state:pc.connectionState};
    \\(await pc.getStats()).forEach(r=>{if(r.type=='inbound-rtp')
    \\for(const k of['framesDecoded','framesDropped','keyFramesDecoded','bytesReceived',
    \\'packetsReceived','packetsLost','nackCount','pliCount','frameWidth','frameHeight',
    \\'framesPerSecond','jitter','freezeCount'])t[k]=r[k]});
    \\window.stats=t;s.textContent=JSON.stringify(t,null,1)},1000)})()
    \\.catch(e=>{s.textContent='error: '+e;window.stats={error:''+e}})
    \\</script>
;

// ---- video ----

var video: [1024 * 1024]u8 = undefined;

fn deliver(picture: []const u8) void {
    const key = isKeyPicture(picture);
    // RTP counts video time in units of 1/90000 s
    const clock: u32 = @truncate(@as(u64, @intCast(nowMs())) * 90);
    lock.lock();
    for (&viewers) |*v| {
        if (!v.active or v.phase != .connected) continue;
        if (key) v.live = true;
        if (v.live) v.sendPicture(picture, clock);
    }
    lock.unlock();
    publish.push(picture, key, nowMs());
    if (publish.needsKeyPicture()) requestKeyPicture();

    raw_lock.lock();
    for (&raw) |*r| {
        if (r.fd < 0) continue;
        if (key) r.live = true;
        if (r.live and !writeAll(r.fd, picture, 2000)) {
            _ = dprintf(2, "k1os-camera: stream reader gone\n");
            _ = close(r.fd);
            r.* = .{};
        }
    }
    raw_lock.unlock();
    _ = pictures_sent.fetchAdd(1, .seq_cst);
}

fn wanted() bool {
    lock.lock();
    const n = connectedViewers();
    lock.unlock();
    return n > 0 or rawReaders() > 0 or publish.active();
}

/// Runs the source command and hands its pictures out while anyone watches.
fn stream() void {
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return;
    const pid = fork();
    if (pid == 0) {
        _ = dup2(fds[1], 1);
        _ = close(fds[0]);
        _ = close(fds[1]);
        const argv = [_]?[*:0]const u8{ "sh", "-c", source_cmd, null };
        _ = execv("/bin/sh", &argv);
        _exit(127);
    }
    _ = close(fds[1]);
    _ = dprintf(2, "k1os-camera: source started\n");
    var len: usize = 0;
    while (wanted()) {
        if (len == video.len) {
            _ = dprintf(2, "k1os-camera: no picture boundary in %lu bytes, dropping\n", @as(c_ulong, len));
            len = 0;
        }
        // the source may stall; keep checking whether anyone still watches
        var p = [1]PollFd{.{ .fd = fds[0], .events = poll_in }};
        if (poll(&p, 1, 1000) == 0) continue;
        const n = read(fds[0], video[len..].ptr, video.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        while (pictureEnd(video[0..len])) |end| {
            deliver(video[0..end]);
            std.mem.copyForwards(u8, video[0 .. len - end], video[end..len]);
            len -= end;
        }
    }
    _ = close(fds[0]);
    _ = kill(pid, @intCast(@intFromEnum(linux.SIG.TERM)));
    _ = waitpid(pid, null, 0);
    _ = dprintf(2, "k1os-camera: source stopped\n");
}

/// Runs `command` in a shell and returns what it printed, or null when it
/// failed or printed more than `out` holds.
fn commandOutput(command: [*:0]const u8, out: []u8) ?[]u8 {
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return null;
    const pid = fork();
    if (pid == 0) {
        _ = dup2(fds[1], 1);
        _ = close(fds[0]);
        _ = close(fds[1]);
        const argv = [_]?[*:0]const u8{ "sh", "-c", command, null };
        _ = execv("/bin/sh", &argv);
        _exit(127);
    }
    _ = close(fds[1]);
    var len: usize = 0;
    while (len < out.len) {
        const n = read(fds[0], out[len..].ptr, out.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    _ = close(fds[0]);
    var exit_status: c_int = 0;
    _ = waitpid(pid, &exit_status, 0);
    return if (pid > 0 and exit_status == 0 and len < out.len) out[0..len] else null;
}

/// k1os-stream hands over each picture here, in one or two pieces.
fn onPicture(_: ?*anyopaque, pieces: [*]const Iovec, count: c_int) callconv(.c) c_int {
    var len: usize = 0;
    for (pieces[0..@intCast(count)]) |piece| {
        if (len + piece.len > video.len) return 0;
        @memcpy(video[len..][0..piece.len], piece.base[0..piece.len]);
        len += piece.len;
    }
    deliver(video[0..len]);
    // a stop, not a failure: the run then ends with 0
    if (!wanted()) k1os_stream_stop();
    return 0;
}

/// The lines the options command prints.
const Options = struct {
    text: [2048]u8 = undefined,
    len: usize = 0,

    fn read(o: *Options) bool {
        const out = commandOutput(source_cmd, o.text[0 .. o.text.len - 1]) orelse return false;
        o.len = out.len;
        o.text[o.len] = 0;
        return true;
    }

    fn lines(o: *Options) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, o.text[0..o.len], '\n');
    }
};

fn isCameraOption(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "--camera-");
}

/// camera.zig asks here how to open the camera.
fn cameraSettings(out: *camera.Settings) bool {
    var options: Options = .{};
    if (!options.read()) return false;
    var have_device = false;
    var lines = options.lines();
    while (lines.next()) |name| {
        if (!isCameraOption(name)) continue;
        const value = lines.next() orelse break;
        if (std.mem.eql(u8, name, "--camera-device")) {
            if (value.len >= out.device.len) return false;
            @memcpy(out.device[0..value.len], value);
            out.device[value.len] = 0;
            have_device = true;
        } else if (std.mem.eql(u8, name, "--camera-fps")) {
            out.fps = std.fmt.parseInt(u32, value, 10) catch return false;
        } else if (std.mem.eql(u8, name, "--camera-size")) {
            const x = std.mem.findScalar(u8, value, 'x') orelse return false;
            out.width = std.fmt.parseInt(u32, value[0..x], 10) catch return false;
            out.height = std.fmt.parseInt(u32, value[x + 1 ..], 10) catch return false;
        }
    }
    return have_device;
}

/// Runs the built-in encoder while anyone watches. Its options come from
/// the command, so that they follow the settings on the printer each time;
/// its frames come from camera.zig.
fn encode() void {
    var options: Options = .{};
    if (!options.read()) {
        _ = dprintf(2, "k1os-camera: the options command failed\n");
        return;
    }
    var program = "k1os-stream".*;
    var argv: [48]?[*:0]u8 = @splat(null);
    argv[0] = &program;
    var argc: usize = 1;
    var ends: [48]usize = undefined;
    var lines = options.lines();
    while (lines.next()) |line| {
        if (isCameraOption(line)) {
            _ = lines.next();
            continue;
        }
        if (argc == argv.len - 1) break;
        argv[argc] = @ptrCast(@constCast(line.ptr));
        ends[argc] = @intFromPtr(line.ptr) - @intFromPtr(&options.text) + line.len;
        argc += 1;
    }
    // Each line ends in its line break or in the terminator behind the text.
    // The breaks become terminators only now: the loop above still needed them.
    for (ends[1..argc]) |end| options.text[end] = 0;

    _ = dprintf(2, "k1os-camera: encoder started\n");
    encoder_running.store(true, .seq_cst);
    const hooks: StreamHooks = .{ .jpeg_fd = -1, .picture = onPicture, .frame = camera.hookFrame, .frame_done = camera.hookDone };
    const result = k1os_stream_run(@intCast(argc), &argv, &hooks);
    encoder_running.store(false, .seq_cst);
    _ = dprintf(2, "k1os-camera: encoder stopped (%d)\n", result);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len != 3) {
        _ = dprintf(2, "usage: %s [<address>:]<port> [helix:]<command>\n", argv[0]);
        return 2;
    }
    const where = std.mem.span(argv[1]);
    const colon = std.mem.findScalar(u8, where, ':');
    const listen_addr: ?[4]u8 = if (colon) |c| parseIpv4(where[0..c]) else .{ 0, 0, 0, 0 };
    const port = std.fmt.parseInt(u16, where[if (colon) |c| c + 1 else 0..], 10) catch 0;
    if (port == 0 or listen_addr == null) {
        _ = dprintf(2, "k1os-camera: bad address or port %s\n", argv[1]);
        return 2;
    }
    source_cmd = argv[2];
    if (std.mem.startsWith(u8, std.mem.span(source_cmd), "helix:")) {
        helix_mode = true;
        source_cmd += "helix:".len;
    }
    const sig_ign: usize = 1;
    _ = signal(@intCast(@intFromEnum(linux.SIG.PIPE)), sig_ign);

    const dtls_error = dtls_global_init(&our_fingerprint);
    if (dtls_error != 0) {
        _ = dprintf(2, "k1os-camera: no certificate (mbedtls -0x%04x)\n", -dtls_error);
        return 1;
    }
    var listener = socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    const one: c_int = 1;
    _ = setsockopt(listener, linux.SOL.SOCKET, linux.SO.REUSEADDR, &one, @sizeOf(c_int));
    const addr: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, port), .addr = listen_addr.? };
    if (listener < 0 or bind(listener, &addr, @sizeOf(SockaddrIn)) != 0 or listen(listener, 8) != 0) {
        _ = dprintf(2, "k1os-camera: cannot listen on port %d\n", @as(c_int, port));
        return 1;
    }
    var thread: c_ulong = 0;
    _ = pthread_create(&thread, null, loopTask, null);
    _ = pthread_create(&thread, null, httpTask, &listener);
    _ = pthread_create(&thread, null, publish.task, null);
    if (helix_mode) {
        camera.settings = cameraSettings;
        camera.needed_elsewhere = wanted;
        _ = pthread_create(&thread, null, camera.task, null);
    }
    _ = dprintf(2, "k1os-camera: listening on %d\n", @as(c_int, port));
    while (true) {
        if (wanted()) {
            const started = nowMs();
            if (helix_mode) encode() else stream();
            // a source that dies at once must not be restarted in a tight loop
            if (nowMs() - started < 2000) _ = usleep(1_000_000);
        }
        _ = usleep(50_000);
    }
}

// ---- tests ----

test {
    _ = stun;
    _ = srtp;
    _ = rtp;
    _ = publish;
}

test "answerFingerprint" {
    const fp = "a4:54:0A:1B:D3:65:3A:B3:C5:F0:E3:72:28:69:B5:D0:AB:08:F8:84:4A:08:3A:5D:8C:C1:B7:78:77:2C:D2:9A";
    const got = answerFingerprint("v=0\r\na=ice-ufrag:x\r\na=fingerprint:sha-256 " ++ fp ++ "\r\na=setup:passive\r\n").?;
    try std.testing.expectEqualStrings("A4:54:0A:1B:D3:65:3A:B3:C5:F0:E3:72:28:69:B5:D0:AB:08:F8:84:4A:08:3A:5D:8C:C1:B7:78:77:2C:D2:9A", &got);
    try std.testing.expectEqual(null, answerFingerprint("v=0\r\na=fingerprint:sha-1 AA:BB\r\n"));
    try std.testing.expectEqual(null, answerFingerprint("a=fingerprint:sha-256 AA:BB\r\n"));
    try std.testing.expectEqual(null, answerFingerprint("a=fingerprint:sha-256 " ++ "Z" ++ fp[1..]));
    try std.testing.expectEqual(null, answerFingerprint("a=fingerprint:sha-256 " ++ fp[0..2] ++ "-" ++ fp[3..]));
}

test "wantsCamera reads uStreamer's addresses" {
    try std.testing.expect(wantsCamera("GET /?action=stream HTTP/1.1\r\nHost: x\r\n\r\n", "stream"));
    try std.testing.expect(wantsCamera("GET /?action=snapshot&t=123 HTTP/1.0\r\n\r\n", "snapshot"));
    try std.testing.expect(wantsCamera("GET /snapshot HTTP/1.1\r\n\r\n", "snapshot"));
    try std.testing.expect(wantsCamera("GET /stream?x=1 HTTP/1.1\r\n\r\n", "stream"));
    try std.testing.expect(!wantsCamera("GET /?action=snapshot HTTP/1.1\r\n\r\n", "stream"));
    try std.testing.expect(!wantsCamera("GET /stream.h264 HTTP/1.1\r\n\r\n", "stream"));
    try std.testing.expect(!wantsCamera("GET / HTTP/1.1\r\nReferer: /?action=stream\r\n\r\n", "stream"));
    try std.testing.expect(!wantsCamera("POST /?action=stream HTTP/1.1\r\n\r\n", "stream"));
}

test "parseIpv4" {
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 114 }, parseIpv4("192.168.1.114").?);
    try std.testing.expectEqual(null, parseIpv4("192.168.1"));
    try std.testing.expectEqual(null, parseIpv4("192.168.1.256"));
    try std.testing.expectEqual(null, parseIpv4("fe80::1"));
}

test "pictureEnd splits at the start code after a slice" {
    const sps_pps_idr = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 1, 0x65, 9, 9, 9 };
    const next = [_]u8{ 0, 0, 0, 1, 0x41, 7, 7, 7, 7 };
    try std.testing.expectEqual(null, pictureEnd(&sps_pps_idr));
    try std.testing.expectEqual(sps_pps_idr.len, pictureEnd(&(sps_pps_idr ++ next)).?);
    const short = [_]u8{ 0, 0, 1, 0x41, 5, 5, 0, 0, 1, 0x41, 6, 6, 6, 6 };
    try std.testing.expectEqual(6, pictureEnd(&short).?);
    try std.testing.expectEqual(null, pictureEnd(&next));
    try std.testing.expect(isKeyPicture(&sps_pps_idr));
    try std.testing.expect(!isKeyPicture(&next));
}

test "jsonString finds members, not values, and unescapes" {
    const body =
        \\{"type":"remote_candidate","id" : "00ab","candidates":[{"candidate":"candidate:1 1 udp","sdpMid":"0"},{"candidate":"two\r\n\u0041\"x"}]}
    ;
    var buf: [64]u8 = undefined;
    var at: usize = 0;
    try std.testing.expectEqualStrings("remote_candidate", jsonString(body, "type", &at, &buf).?);
    at = 0;
    try std.testing.expectEqualStrings("00ab", jsonString(body, "id", &at, &buf).?);
    at = 0;
    try std.testing.expectEqualStrings("candidate:1 1 udp", jsonString(body, "candidate", &at, &buf).?);
    try std.testing.expectEqualStrings("two\r\nA\"x", jsonString(body, "candidate", &at, &buf).?);
    try std.testing.expectEqual(null, jsonString(body, "candidate", &at, &buf));
    at = 0;
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(null, jsonString(body, "type", &at, &small));
    at = 0;
    try std.testing.expectEqual(null, jsonString("{\"sdp\":\"unterminated", "sdp", &at, &buf));
}

test "jsonEscape round-trips an SDP through jsonString" {
    const sdp = "v=0\r\na=x:\"q\"\\\r\n";
    var escaped: [64]u8 = undefined;
    var wrapped: [96]u8 = undefined;
    var back: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&wrapped, "{{\"sdp\":\"{s}\"}}", .{jsonEscape(sdp, &escaped).?});
    var at: usize = 0;
    try std.testing.expectEqualStrings(sdp, jsonString(body, "sdp", &at, &back).?);
}

test "headerValue and clientIp" {
    const headers = "POST /webrtc HTTP/1.1\r\nHost: k1\r\ncontent-length: 42\r\nX-Real-IP: 192.168.1.114\r\n\r\n";
    try std.testing.expectEqualStrings("42", headerValue(headers, "Content-Length").?);
    try std.testing.expectEqual(null, headerValue(headers, "Cookie"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.1.114", clientIp(.{ .addr = .{ 127, 0, 0, 1 } }, headers, &buf));
    try std.testing.expectEqualStrings("10.0.0.9", clientIp(.{ .addr = .{ 10, 0, 0, 9 } }, headers, &buf));
}

test "watchingViewers counts the connected viewers that are still heard from" {
    viewers = @splat(.{});
    defer viewers = @splat(.{});
    viewers[0] = .{ .active = true, .phase = .connected, .last_check_ms = 10_000 };
    viewers[1] = .{ .active = true, .phase = .connected, .last_check_ms = 10_000 - stale_ms - 1 };
    viewers[2] = .{ .active = true, .phase = .handshaking, .last_check_ms = 10_000 };
    try std.testing.expectEqual(1, watchingViewers(10_000));
    viewers[3] = .{ .active = true, .phase = .connected, .last_check_ms = 10_000 - stale_ms };
    try std.testing.expectEqual(2, watchingViewers(10_000));
}
