//! What publishing a live stream over RTMP takes (Adobe's RTMP specification
//! of 2012, and the FLV tag bodies it carries): the chunk stream in both
//! directions, AMF0 values for the commands, and H.264 and AAC as FLV video
//! and audio data. No sockets here; publish.zig drives it.
const std = @import("std");
const NalIterator = @import("rtp.zig").NalIterator;

pub const handshake_len = 1536;
/// until a peer says otherwise (5.4.1)
pub const default_chunk_size = 128;

pub const MessageType = enum(u8) {
    set_chunk_size = 1,
    abort = 2,
    acknowledgement = 3,
    user_control = 4,
    window_ack_size = 5,
    set_peer_bandwidth = 6,
    audio = 8,
    video = 9,
    data_amf0 = 18,
    command_amf0 = 20,
    _,
};

// ---- chunk stream, sending ----

/// Writes one message as chunks of at most `chunk_size` payload bytes.
/// Every message gets a full header (format 0), which costs a few bytes over
/// the compressed forms and needs no memory of the previous message.
/// `sink` has `fn write(sink, []const u8) !void`.
pub fn writeMessage(sink: anytype, chunk_size: usize, chunk_stream: u6, kind: MessageType, stream_id: u32, timestamp: u32, payload: []const u8) !void {
    std.debug.assert(chunk_stream >= 2);
    // A timestamp that does not fit three bytes is written as 0xffffff and
    // then in full, also in front of every continuation chunk (5.3.1.3).
    const extended = timestamp >= 0xffffff;
    var header: [1 + 11 + 4]u8 = undefined;
    header[0] = chunk_stream; // format 0
    std.mem.writeInt(u24, header[1..4], if (extended) 0xffffff else @intCast(timestamp), .big);
    std.mem.writeInt(u24, header[4..7], @intCast(payload.len), .big);
    header[7] = @intFromEnum(kind);
    std.mem.writeInt(u32, header[8..12], stream_id, .little);
    std.mem.writeInt(u32, header[12..16], timestamp, .big);
    try sink.write(header[0..if (extended) 16 else 12]);

    var at: usize = 0;
    while (true) {
        const n = @min(chunk_size, payload.len - at);
        try sink.write(payload[at..][0..n]);
        at += n;
        if (at == payload.len) return;
        var continuation: [5]u8 = undefined;
        continuation[0] = 0xc0 | @as(u8, chunk_stream); // format 3
        std.mem.writeInt(u32, continuation[1..5], timestamp, .big);
        try sink.write(continuation[0..if (extended) 5 else 1]);
    }
}

// ---- chunk stream, receiving ----

pub const Message = struct {
    kind: MessageType,
    stream_id: u32,
    /// valid until the next call; empty for a message larger than the
    /// reader keeps, which a publisher has no use for
    payload: []const u8,
};

/// Reads the messages a server sends. `Source` has
/// `fn readExact(source, []u8) !void`.
pub fn Reader(comptime Source: type) type {
    return struct {
        const Self = @This();
        const Header = struct { timestamp: u32 = 0, length: u32 = 0, kind: u8 = 0, stream_id: u32 = 0, extended: bool = false };

        source: Source,
        chunk_size: usize = default_chunk_size,
        /// the last header on each chunk stream; later chunks leave out
        /// what has not changed
        headers: [64]Header = @splat(.{}),
        buf: [4096]u8 = undefined,

        pub fn next(r: *Self) !Message {
            var assembling: ?u6 = null;
            var have: usize = 0;
            while (true) {
                var first: [1]u8 = undefined;
                try r.source.readExact(&first);
                const format = first[0] >> 6;
                const id: u6 = @truncate(first[0]);
                // ids 0 and 1 announce a longer id; no server uses those for
                // the few messages a publisher gets
                if (id < 2) return error.UnsupportedChunkStream;
                // one message at a time: chunks of another message in between
                // would need a buffer per chunk stream
                if (assembling) |a| {
                    if (a != id or format != 3) return error.InterleavedChunks;
                }
                const h = &r.headers[id];
                var raw: [11]u8 = undefined;
                const header_len: usize = switch (format) {
                    0 => 11,
                    1 => 7,
                    2 => 3,
                    else => 0,
                };
                try r.source.readExact(raw[0..header_len]);
                if (format <= 2) {
                    const field = std.mem.readInt(u24, raw[0..3], .big);
                    h.extended = field == 0xffffff;
                    if (!h.extended) h.timestamp = if (format == 0) field else h.timestamp +% field;
                }
                if (format <= 1) {
                    h.length = std.mem.readInt(u24, raw[3..6], .big);
                    h.kind = raw[6];
                }
                if (format == 0) h.stream_id = std.mem.readInt(u32, raw[7..11], .little);
                if (h.extended) {
                    var full: [4]u8 = undefined;
                    try r.source.readExact(&full);
                    if (format <= 2) h.timestamp = std.mem.readInt(u32, &full, .big);
                }

                const n = @min(r.chunk_size, h.length - have);
                if (h.length <= r.buf.len) {
                    try r.source.readExact(r.buf[have..][0..n]);
                } else {
                    var left = n;
                    while (left > 0) {
                        const part = @min(left, r.buf.len);
                        try r.source.readExact(r.buf[0..part]);
                        left -= part;
                    }
                }
                have += n;
                if (have < h.length) {
                    assembling = id;
                    continue;
                }
                const payload: []const u8 = if (h.length <= r.buf.len) r.buf[0..h.length] else &.{};
                const kind: MessageType = @enumFromInt(h.kind);
                if (kind == .set_chunk_size and payload.len >= 4) {
                    const size = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
                    if (size == 0) return error.BadChunkSize;
                    r.chunk_size = size;
                }
                return .{ .kind = kind, .stream_id = h.stream_id, .payload = payload };
            }
        }
    };
}

// ---- AMF0 ----

/// Appends AMF0 values to a fixed buffer.
pub const Amf = struct {
    buf: []u8,
    len: usize = 0,

    fn put(a: *Amf, data: []const u8) void {
        @memcpy(a.buf[a.len..][0..data.len], data);
        a.len += data.len;
    }

    fn key(a: *Amf, name: []const u8) void {
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(name.len), .big);
        a.put(&len);
        a.put(name);
    }

    pub fn number(a: *Amf, value: f64) void {
        var bits: [8]u8 = undefined;
        std.mem.writeInt(u64, &bits, @bitCast(value), .big);
        a.put(&.{0x00});
        a.put(&bits);
    }

    pub fn boolean(a: *Amf, value: bool) void {
        a.put(&.{ 0x01, @intFromBool(value) });
    }

    pub fn string(a: *Amf, text: []const u8) void {
        a.put(&.{0x02});
        a.key(text);
    }

    pub fn null_(a: *Amf) void {
        a.put(&.{0x05});
    }

    pub fn objectStart(a: *Amf) void {
        a.put(&.{0x03});
    }

    /// an array with names; the count is a hint and may be zero
    pub fn arrayStart(a: *Amf) void {
        a.put(&.{ 0x08, 0, 0, 0, 0 });
    }

    pub fn objectEnd(a: *Amf) void {
        a.put(&.{ 0, 0, 0x09 });
    }

    pub fn numberField(a: *Amf, name: []const u8, value: f64) void {
        a.key(name);
        a.number(value);
    }

    pub fn stringField(a: *Amf, name: []const u8, text: []const u8) void {
        a.key(name);
        a.string(text);
    }

    pub fn booleanField(a: *Amf, name: []const u8, value: bool) void {
        a.key(name);
        a.boolean(value);
    }

    pub fn bytes(a: *const Amf) []const u8 {
        return a.buf[0..a.len];
    }
};

/// The start of a command a server sends: its name and transaction number,
/// and what follows them.
pub const Command = struct {
    name: []const u8,
    transaction: f64,
    rest: []const u8,

    pub fn parse(payload: []const u8) ?Command {
        if (payload.len < 3 or payload[0] != 0x02) return null;
        const name_len = std.mem.readInt(u16, payload[1..3], .big);
        if (payload.len < 3 + name_len + 9 or payload[3 + name_len] != 0x00) return null;
        const number_at = 3 + name_len + 1;
        return .{
            .name = payload[3..][0..name_len],
            .transaction = @bitCast(std.mem.readInt(u64, payload[number_at..][0..8], .big)),
            .rest = payload[number_at + 8 ..],
        };
    }

    /// A reply made of null and a number: createStream's stream id.
    pub fn numberAfterNull(c: Command) ?f64 {
        if (c.rest.len < 10 or c.rest[0] != 0x05 or c.rest[1] != 0x00) return null;
        return @bitCast(std.mem.readInt(u64, c.rest[2..10], .big));
    }
};

// ---- FLV bodies ----

pub const aac_sample_rate = 44100;
pub const aac_frame_samples = 1024;
/// AudioSpecificConfig: AAC LC, 44100 Hz, one channel
pub const aac_config = [_]u8{ 0x12, 0x08 };
/// One AAC LC frame of silence for that configuration, as ffmpeg's encoder
/// writes it (taken from its ADTS output, without the ADTS header).
pub const aac_silence = [_]u8{ 0x01, 0x18, 0x20, 0x07 };
/// FLV audio tag header: AAC, 44 kHz, 16 bit, stereo. For AAC the last three
/// are fixed like this whatever the stream has; the real values are in the
/// configuration.
pub const audio_tag = 0xaf;

/// The first parameter sets of a picture.
pub fn parameterSets(picture: []const u8) ?struct { sps: []const u8, pps: []const u8 } {
    var sps: ?[]const u8 = null;
    var pps: ?[]const u8 = null;
    var nals: NalIterator = .{ .data = picture };
    while (nals.next()) |nal| switch (nal[0] & 0x1f) {
        7 => sps = sps orelse nal,
        8 => pps = pps orelse nal,
        else => {},
    };
    if (sps == null or pps == null or sps.?.len < 4) return null;
    return .{ .sps = sps.?, .pps = pps.? };
}

/// The video message that must come first: the decoder configuration
/// (ISO 14496-15 5.2.4.1) with one SPS and one PPS.
pub fn videoConfig(sps: []const u8, pps: []const u8, out: []u8) ?[]u8 {
    const len = 5 + 6 + 2 + sps.len + 1 + 2 + pps.len;
    if (out.len < len or sps.len < 4 or sps.len > 0xffff or pps.len > 0xffff) return null;
    out[0..5].* = .{ 0x17, 0, 0, 0, 0 }; // key frame, AVC; sequence header
    out[5..11].* = .{ 1, sps[1], sps[2], sps[3], 0xff, 0xe1 }; // profile and level from the SPS; four byte NAL lengths; one SPS
    std.mem.writeInt(u16, out[11..13], @intCast(sps.len), .big);
    @memcpy(out[13..][0..sps.len], sps);
    var at = 13 + sps.len;
    out[at] = 1;
    std.mem.writeInt(u16, out[at + 1 ..][0..2], @intCast(pps.len), .big);
    at += 3;
    @memcpy(out[at..][0..pps.len], pps);
    return out[0..len];
}

/// A picture as a video message: its slices with a length in front of each
/// instead of a start code. Parameter sets and delimiters stay out; the
/// configuration has the former. Null when `out` is too small.
pub fn videoFrame(picture: []const u8, key: bool, out: []u8) ?[]u8 {
    if (out.len < 5) return null;
    out[0..5].* = .{ if (key) 0x17 else 0x27, 1, 0, 0, 0 }; // AVC; NAL units; shown when decoded
    var len: usize = 5;
    var nals: NalIterator = .{ .data = picture };
    while (nals.next()) |nal| {
        switch (nal[0] & 0x1f) {
            7, 8, 9 => continue,
            else => {},
        }
        if (len + 4 + nal.len > out.len) return null;
        std.mem.writeInt(u32, out[len..][0..4], @intCast(nal.len), .big);
        @memcpy(out[len + 4 ..][0..nal.len], nal);
        len += 4 + nal.len;
    }
    return if (len > 5) out[0..len] else null;
}

/// "rtmp://host[:port]/app" taken apart.
pub const Url = struct {
    host: []const u8,
    port: u16,
    app: []const u8,

    pub fn parse(url: []const u8) ?Url {
        const scheme = "rtmp://";
        if (!std.mem.startsWith(u8, url, scheme)) return null;
        const rest = url[scheme.len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
        var host = rest[0..slash];
        var port: u16 = 1935;
        if (std.mem.findScalar(u8, host, ':')) |colon| {
            port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch return null;
            host = host[0..colon];
        }
        const app = std.mem.trimEnd(u8, rest[slash + 1 ..], "/");
        if (host.len == 0 or host.len > 253 or app.len == 0) return null;
        for (host) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-') return null;
        }
        return .{ .host = host, .port = port, .app = app };
    }
};

// ---- tests ----

const TestPipe = struct {
    data: [20000]u8 = undefined,
    len: usize = 0,
    at: usize = 0,

    fn write(p: *TestPipe, bytes: []const u8) !void {
        @memcpy(p.data[p.len..][0..bytes.len], bytes);
        p.len += bytes.len;
    }

    fn readExact(p: *TestPipe, out: []u8) !void {
        if (p.at + out.len > p.len) return error.EndOfStream;
        @memcpy(out, p.data[p.at..][0..out.len]);
        p.at += out.len;
    }
};

test "writeMessage: one chunk, the layout of the specification" {
    var pipe: TestPipe = .{};
    try writeMessage(&pipe, 128, 3, .command_amf0, 1, 0x010203, "abc");
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x01, 0x02, 0x03, 0, 0, 3, 20, 1, 0, 0, 0, 'a', 'b', 'c' }, pipe.data[0..pipe.len]);
}

test "messages written in chunks are read back, with and without extended timestamps" {
    var pipe: TestPipe = .{};
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 7);
    try writeMessage(&pipe, 128, 6, .video, 1, 1000, big[0..300]);
    try writeMessage(&pipe, 128, 4, .audio, 1, 0x1234567, big[0..4]); // above 0xffffff
    try writeMessage(&pipe, 128, 6, .video, 1, 0x2000000, big[0..1000]); // extended, with continuations
    try writeMessage(&pipe, 128, 2, .set_chunk_size, 0, 0, &.{ 0, 0, 0x10, 0 });
    try writeMessage(&pipe, 4096, 6, .video, 1, 5, &big); // more than the reader keeps
    try writeMessage(&pipe, 4096, 3, .command_amf0, 0, 6, big[0..4096]);
    // 300 bytes at 128 per chunk: two continuation headers of one byte
    var reader: Reader(*TestPipe) = .{ .source = &pipe };

    var m = try reader.next();
    try std.testing.expectEqual(MessageType.video, m.kind);
    try std.testing.expectEqual(1, m.stream_id);
    try std.testing.expectEqualSlices(u8, big[0..300], m.payload);
    m = try reader.next();
    try std.testing.expectEqual(MessageType.audio, m.kind);
    try std.testing.expectEqualSlices(u8, big[0..4], m.payload);
    try std.testing.expectEqual(0x1234567, reader.headers[4].timestamp);
    m = try reader.next();
    try std.testing.expectEqualSlices(u8, big[0..1000], m.payload);
    try std.testing.expectEqual(0x2000000, reader.headers[6].timestamp);
    m = try reader.next();
    try std.testing.expectEqual(MessageType.set_chunk_size, m.kind);
    try std.testing.expectEqual(4096, reader.chunk_size);
    m = try reader.next();
    try std.testing.expectEqual(MessageType.video, m.kind);
    try std.testing.expectEqual(0, m.payload.len);
    m = try reader.next();
    try std.testing.expectEqualSlices(u8, big[0..4096], m.payload);
    try std.testing.expectError(error.EndOfStream, reader.next());
}

test "the reader follows compressed headers and refuses what it cannot follow" {
    var pipe: TestPipe = .{};
    // format 0, then format 1 (new length and type, same stream), then
    // format 2 (only a time delta), then format 3 (a new message, all as before)
    try pipe.write(&.{ 0x03, 0, 0, 10, 0, 0, 2, 20, 5, 0, 0, 0, 'a', 'b' });
    try pipe.write(&.{ 0x43, 0, 0, 5, 0, 0, 3, 18, 'c', 'd', 'e' });
    try pipe.write(&.{ 0x83, 0, 0, 7, 'f', 'g', 'h' });
    try pipe.write(&.{ 0xc3, 'i', 'j', 'k' });
    var reader: Reader(*TestPipe) = .{ .source = &pipe };
    try std.testing.expectEqualStrings("ab", (try reader.next()).payload);
    var m = try reader.next();
    try std.testing.expectEqual(MessageType.data_amf0, m.kind);
    try std.testing.expectEqual(5, m.stream_id);
    try std.testing.expectEqualStrings("cde", m.payload);
    try std.testing.expectEqual(15, reader.headers[3].timestamp);
    m = try reader.next();
    try std.testing.expectEqualStrings("fgh", m.payload);
    try std.testing.expectEqual(22, reader.headers[3].timestamp);
    try std.testing.expectEqualStrings("ijk", (try reader.next()).payload);

    var long_id: TestPipe = .{};
    try long_id.write(&.{ 0x00, 5, 0, 0, 0 });
    var r2: Reader(*TestPipe) = .{ .source = &long_id };
    try std.testing.expectError(error.UnsupportedChunkStream, r2.next());

    var mixed: TestPipe = .{};
    try mixed.write(&(.{ 0x03, 0, 0, 0, 0, 0, 200, 20, 0, 0, 0, 0 } ++ @as([128]u8, @splat(1)) ++ .{ 0x04, 0, 0, 0, 0, 0, 1, 20, 0, 0, 0, 0, 9 }));
    var r3: Reader(*TestPipe) = .{ .source = &mixed };
    try std.testing.expectError(error.InterleavedChunks, r3.next());

    var zero: TestPipe = .{};
    try writeMessage(&zero, 128, 2, .set_chunk_size, 0, 0, &.{ 0, 0, 0, 0 });
    var r4: Reader(*TestPipe) = .{ .source = &zero };
    try std.testing.expectError(error.BadChunkSize, r4.next());
}

test "AMF0 values and a command read back" {
    var buf: [128]u8 = undefined;
    var a: Amf = .{ .buf = &buf };
    a.string("_result");
    a.number(4);
    a.null_();
    a.number(1);
    try std.testing.expectEqualSlices(u8, &(.{ 0x02, 0, 7 } ++ "_result".* ++ .{ 0x00, 0x40, 0x10, 0, 0, 0, 0, 0, 0, 0x05, 0x00, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 }), a.bytes());
    const command = Command.parse(a.bytes()).?;
    try std.testing.expectEqualStrings("_result", command.name);
    try std.testing.expectEqual(4, command.transaction);
    try std.testing.expectEqual(1, command.numberAfterNull().?);

    var o: Amf = .{ .buf = &buf };
    o.objectStart();
    o.stringField("app", "live");
    o.booleanField("fpad", false);
    o.objectEnd();
    try std.testing.expectEqualSlices(u8, &(.{ 0x03, 0, 3 } ++ "app".* ++ .{ 0x02, 0, 4 } ++ "live".* ++ .{ 0, 4 } ++ "fpad".* ++ .{ 0x01, 0, 0, 0, 0x09 }), o.bytes());

    try std.testing.expectEqual(null, Command.parse(&.{ 0x02, 0, 9, 'x' }));
    try std.testing.expectEqual(null, Command.parse(&.{ 0x05, 0, 0 }));
    try std.testing.expectEqual(null, (Command{ .name = "", .transaction = 0, .rest = &.{ 0x05, 0x02 } }).numberAfterNull());
}

test "video messages from an Annex B picture" {
    const picture = [_]u8{ 0, 0, 0, 1, 0x09, 0xf0 } ++ // delimiter
        [_]u8{ 0, 0, 0, 1, 0x67, 0x4d, 0x40, 0x1f, 0xda } ++ // SPS: Main, level 3.1
        [_]u8{ 0, 0, 0, 1, 0x68, 0xee, 0x38, 0x80 } ++ // PPS
        [_]u8{ 0, 0, 1, 0x65, 1, 2, 3 }; // IDR slice
    const sets = parameterSets(&picture).?;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{
        0x17, 0,    0,    0,    0,
        1,    0x4d, 0x40, 0x1f, 0xff,
        0xe1, 0,    5,    0x67, 0x4d,
        0x40, 0x1f, 0xda, 1,    0,
        4,    0x68, 0xee, 0x38, 0x80,
    }, videoConfig(sets.sps, sets.pps, &buf).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x17, 1, 0, 0, 0, 0, 0, 0, 4, 0x65, 1, 2, 3 }, videoFrame(&picture, true, &buf).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x27, 1, 0, 0, 0, 0, 0, 0, 2, 0x41, 9 }, videoFrame(&.{ 0, 0, 1, 0x41, 9 }, false, &buf).?);
    try std.testing.expectEqual(null, videoFrame(&picture, true, buf[0..10]));
    try std.testing.expectEqual(null, videoFrame(&.{ 0, 0, 1, 0x67, 1, 2, 3 }, true, &buf));
    try std.testing.expectEqual(null, parameterSets(&.{ 0, 0, 1, 0x41, 9 }));
}

test "Url.parse" {
    const twitch = Url.parse("rtmp://live.twitch.tv/app").?;
    try std.testing.expectEqualStrings("live.twitch.tv", twitch.host);
    try std.testing.expectEqual(1935, twitch.port);
    try std.testing.expectEqualStrings("app", twitch.app);
    const local = Url.parse("rtmp://127.0.0.1:1936/live/").?;
    try std.testing.expectEqual(1936, local.port);
    try std.testing.expectEqualStrings("live", local.app);
    try std.testing.expectEqual(null, Url.parse("rtmps://live.twitch.tv/app"));
    try std.testing.expectEqual(null, Url.parse("rtmp://live.twitch.tv"));
    try std.testing.expectEqual(null, Url.parse("rtmp://live.twitch.tv/"));
    try std.testing.expectEqual(null, Url.parse("rtmp://host:x/app"));
    try std.testing.expectEqual(null, Url.parse("rtmp://ho st/app"));
}
