//! H.264 pictures as RTP payloads (RFC 6184, packetization mode 1) and the
//! RTCP feedback a receiver sends about them.
const std = @import("std");

pub const header_len = 12;
/// Payload bytes per packet. With the RTP header, the SRTP tag, UDP and IP
/// this stays under 1280 bytes, the smallest MTU a path may have.
pub const max_payload = 1200;

pub fn writeHeader(out: *[header_len]u8, payload_type: u7, marker: bool, seq: u16, timestamp: u32, ssrc: u32) void {
    out[0] = 0x80; // version 2
    out[1] = @as(u8, payload_type) | @as(u8, @intFromBool(marker)) << 7;
    std.mem.writeInt(u16, out[2..4], seq, .big);
    std.mem.writeInt(u32, out[4..8], timestamp, .big);
    std.mem.writeInt(u32, out[8..12], ssrc, .big);
}

/// The NAL units of an Annex B byte stream, without their start codes.
pub const NalIterator = struct {
    data: []const u8,
    at: usize = 0,

    fn startCode(data: []const u8, from: usize) ?usize {
        var i = from;
        while (i + 3 <= data.len) : (i += 1) {
            if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) return i;
        }
        return null;
    }

    pub fn next(it: *NalIterator) ?[]const u8 {
        while (true) {
            const start = (startCode(it.data, it.at) orelse return null) + 3;
            const end = startCode(it.data, start) orelse it.data.len;
            it.at = end;
            // A unit never ends in a zero byte; zeros before the next start
            // code belong to that code or are padding.
            const nal = std.mem.trimEnd(u8, it.data[start..end], &.{0});
            if (nal.len > 0) return nal;
        }
    }
};

/// Length of the first complete picture at the start of `buf` (parameter
/// sets included): up to the start code that follows its first slice.
/// Null while that start code has not arrived yet.
pub fn pictureEnd(buf: []const u8) ?usize {
    var slice_seen = false;
    var i: usize = 0;
    while (i + 4 < buf.len) : (i += 1) {
        if (buf[i] != 0 or buf[i + 1] != 0 or buf[i + 2] != 1) continue;
        if (slice_seen) return if (i > 0 and buf[i - 1] == 0) i - 1 else i;
        const nal_type = buf[i + 3] & 0x1f;
        if (nal_type == 1 or nal_type == 5) slice_seen = true;
        i += 2;
    }
    return null;
}

/// Can a decoder start at this picture (does it hold an IDR slice)?
pub fn isKeyPicture(picture: []const u8) bool {
    var i: usize = 0;
    while (i + 3 < picture.len) : (i += 1) {
        if (picture[i] == 0 and picture[i + 1] == 0 and picture[i + 2] == 1 and picture[i + 3] & 0x1f == 5) return true;
    }
    return false;
}

/// One RTP payload: up to two bytes written here, then a part of the picture.
pub const Payload = struct {
    prefix: [2]u8 = undefined,
    prefix_len: usize = 0,
    body: []const u8,
    /// the last packet of the picture carries the marker bit
    marker: bool,
};

/// Cuts a picture into RTP payloads: a NAL unit that fits travels as it is,
/// a larger one in fragments (FU-A).
pub const Packetizer = struct {
    nals: NalIterator,
    nal: ?[]const u8 = null,
    /// the unit after `nal`, read ahead to know which packet is the last
    following: ?[]const u8 = null,
    /// offset into `nal` when it is being sent in fragments, else 0
    offset: usize = 0,

    pub fn init(picture: []const u8) Packetizer {
        var p: Packetizer = .{ .nals = .{ .data = picture } };
        p.nal = p.nals.next();
        p.following = p.nals.next();
        return p;
    }

    fn advance(p: *Packetizer) void {
        p.nal = p.following;
        p.following = p.nals.next();
        p.offset = 0;
    }

    pub fn next(p: *Packetizer) ?Payload {
        const nal = p.nal orelse return null;
        const last_nal = p.following == null;
        if (nal.len <= max_payload) {
            p.advance();
            return .{ .body = nal, .marker = last_nal };
        }
        // FU-A: an indicator with the unit's importance bits and type 28,
        // then a header with start and end flags and the unit's own type.
        const start = p.offset == 0;
        if (start) p.offset = 1; // the unit's header byte is not repeated
        const n = @min(max_payload - 2, nal.len - p.offset);
        const body = nal[p.offset..][0..n];
        p.offset += n;
        const end = p.offset == nal.len;
        const flags: u8 = @as(u8, @intFromBool(start)) << 7 | @as(u8, @intFromBool(end)) << 6;
        if (end) p.advance();
        return .{
            .prefix = .{ (nal[0] & 0xe0) | 28, flags | (nal[0] & 0x1f) },
            .prefix_len = 2,
            .body = body,
            .marker = end and last_nal,
        };
    }
};

/// The sequence numbers a compound RTCP packet reports as lost (generic NACK,
/// RFC 4585 6.2.1: a packet id and a bit mask for the sixteen after it).
pub fn nackedPackets(rtcp: []const u8, out: []u16) []u16 {
    var n: usize = 0;
    var pos: usize = 0;
    while (pos + 4 <= rtcp.len) {
        const size = (@as(usize, std.mem.readInt(u16, rtcp[pos + 2 ..][0..2], .big)) + 1) * 4;
        if (pos + size > rtcp.len) break;
        const transport_feedback = rtcp[pos + 1] == 205;
        const generic_nack = rtcp[pos] & 0x1f == 1;
        if (transport_feedback and generic_nack) {
            var at = pos + 12; // header, sender and media source
            while (at + 4 <= pos + size) : (at += 4) {
                const first = std.mem.readInt(u16, rtcp[at..][0..2], .big);
                const mask = std.mem.readInt(u16, rtcp[at + 2 ..][0..2], .big);
                if (n == out.len) return out;
                out[n] = first;
                n += 1;
                for (0..16) |bit| {
                    if (mask >> @intCast(bit) & 1 == 0) continue;
                    if (n == out.len) return out;
                    out[n] = first +% @as(u16, @intCast(bit + 1));
                    n += 1;
                }
            }
        }
        pos += size;
    }
    return out[0..n];
}

/// Does a compound RTCP packet ask for a key picture? That is a picture loss
/// indication (RFC 4585 6.3.1) or a full intra request (RFC 5104 4.3.1).
pub fn asksForKeyPicture(rtcp: []const u8) bool {
    var pos: usize = 0;
    while (pos + 4 <= rtcp.len) {
        const size = (@as(usize, std.mem.readInt(u16, rtcp[pos + 2 ..][0..2], .big)) + 1) * 4;
        if (pos + size > rtcp.len) break;
        const format = rtcp[pos] & 0x1f;
        if (rtcp[pos + 1] == 206 and (format == 1 or format == 4)) return true;
        pos += size;
    }
    return false;
}

/// RTP and RTCP share a port; RTCP packet types 192 to 223 sit where RTP has
/// its marker bit and payload type (RFC 5761).
pub fn isRtcp(datagram: []const u8) bool {
    return datagram.len >= 8 and datagram[0] >> 6 == 2 and datagram[1] >= 192 and datagram[1] <= 223;
}

/// The last packets sent to one viewer, as they went onto the wire, found
/// again by RTP sequence number. 256 packets are about a second of video at
/// 2.5 Mbit/s; a browser asks within a few hundred milliseconds.
pub const Resend = struct {
    const slots = 256;
    pub const max_packet = 1400;
    len: [slots]u16 = @splat(0),
    data: [slots][max_packet]u8 = undefined,

    pub fn clear(r: *Resend) void {
        r.len = @splat(0);
    }

    pub fn store(r: *Resend, packet: []const u8) void {
        if (packet.len < header_len or packet.len > max_packet) return;
        const slot = packet[3]; // the low byte of the sequence number
        @memcpy(r.data[slot][0..packet.len], packet);
        r.len[slot] = @intCast(packet.len);
    }

    pub fn find(r: *const Resend, seq: u16) ?[]const u8 {
        const slot: u8 = @truncate(seq);
        const packet = r.data[slot][0..r.len[slot]];
        if (packet.len == 0 or std.mem.readInt(u16, packet[2..4], .big) != seq) return null;
        return packet;
    }
};

// ---- tests ----

test "writeHeader" {
    var h: [header_len]u8 = undefined;
    writeHeader(&h, 96, true, 0x1234, 0x01020304, 0xa1b2c3d4);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0xe0, 0x12, 0x34, 1, 2, 3, 4, 0xa1, 0xb2, 0xc3, 0xd4 }, &h);
    writeHeader(&h, 96, false, 0, 0, 0);
    try std.testing.expectEqual(96, h[1]);
}

test "NalIterator finds units behind three and four byte start codes" {
    const stream = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 1, 0x65, 9, 0, 9, 0, 0 };
    var it: NalIterator = .{ .data = &stream };
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 1, 2 }, it.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 0x68, 3 }, it.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 9, 0, 9 }, it.next().?);
    try std.testing.expectEqual(null, it.next());
    var none: NalIterator = .{ .data = &.{ 1, 2, 3, 0, 0 } };
    try std.testing.expectEqual(null, none.next());
    var empty: NalIterator = .{ .data = &.{ 0, 0, 1, 0, 0, 1, 0x41, 5 } };
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 5 }, empty.next().?);
}

test "Packetizer sends small units whole and marks the last packet" {
    const picture = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 1, 0x65, 9, 9 };
    var p = Packetizer.init(&picture);
    const sps = p.next().?;
    try std.testing.expectEqual(0, sps.prefix_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 1, 2 }, sps.body);
    try std.testing.expect(!sps.marker);
    try std.testing.expect(!p.next().?.marker);
    const slice = p.next().?;
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 9, 9 }, slice.body);
    try std.testing.expect(slice.marker);
    try std.testing.expectEqual(null, p.next());
}

test "Packetizer fragments a large unit and the fragments rebuild it" {
    // parameter set, then a slice of 3000 bytes, then a small one
    var picture: [4 + 2 + 3 + 3000 + 3 + 2]u8 = undefined;
    picture[0..6].* = .{ 0, 0, 0, 1, 0x68, 3 };
    picture[6..9].* = .{ 0, 0, 1 };
    const big = picture[9..][0..3000];
    for (big, 0..) |*byte, i| byte.* = @intCast(i % 251 + 1);
    big[0] = 0x65; // important (nal_ref_idc 3), type 5
    picture[3009..].* = .{ 0, 0, 1, 0x41, 7 };

    var p = Packetizer.init(&picture);
    try std.testing.expectEqualSlices(u8, &.{ 0x68, 3 }, p.next().?.body);
    var rebuilt: [3000]u8 = undefined;
    rebuilt[0] = 0x65;
    var n: usize = 1;
    var fragments: usize = 0;
    while (fragments < 3) : (fragments += 1) {
        const f = p.next().?;
        try std.testing.expectEqual(2, f.prefix_len);
        try std.testing.expectEqual(0x60 | 28, f.prefix[0]);
        try std.testing.expectEqual(5, f.prefix[1] & 0x1f);
        try std.testing.expectEqual(fragments == 0, f.prefix[1] & 0x80 != 0);
        try std.testing.expectEqual(fragments == 2, f.prefix[1] & 0x40 != 0);
        try std.testing.expect(f.prefix_len + f.body.len <= max_payload);
        try std.testing.expect(!f.marker); // another unit follows
        @memcpy(rebuilt[n..][0..f.body.len], f.body);
        n += f.body.len;
    }
    try std.testing.expectEqualSlices(u8, big, rebuilt[0..n]);
    const last = p.next().?;
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 7 }, last.body);
    try std.testing.expect(last.marker);
    try std.testing.expectEqual(null, p.next());

    // when the large unit is the last one, its final fragment has the marker
    var q = Packetizer.init(picture[0..3009]);
    _ = q.next();
    try std.testing.expect(!q.next().?.marker);
    try std.testing.expect(!q.next().?.marker);
    try std.testing.expect(q.next().?.marker);
    try std.testing.expectEqual(null, q.next());
}

test "nackedPackets reads generic NACKs out of a compound packet" {
    const receiver_report = [_]u8{ 0x80, 201, 0, 1, 0, 0, 0, 1 };
    const nack = [_]u8{ 0x81, 205, 0, 4, 0, 0, 0, 1, 0, 0, 0, 2 } ++
        [_]u8{ 0x00, 0x64, 0b1000_0000, 0b0000_0101 } ++ // 100, then 101, 103 and 116
        [_]u8{ 0xff, 0xff, 0x00, 0x01 }; // 65535 and, wrapping, 0
    const picture_loss = [_]u8{ 0x81, 206, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2 };
    var out: [64]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 100, 101, 103, 116, 65535, 0 }, nackedPackets(&(receiver_report ++ nack ++ picture_loss), &out));
    try std.testing.expectEqual(0, nackedPackets(&(receiver_report ++ picture_loss), &out).len);
    try std.testing.expectEqual(0, nackedPackets(&[_]u8{ 0x81, 205, 0xff, 0xff, 0, 0, 0, 1 }, &out).len);
    try std.testing.expectEqual(0, nackedPackets(nack[0..3], &out).len);
    var two: [2]u16 = undefined;
    try std.testing.expectEqualSlices(u16, &.{ 100, 101 }, nackedPackets(&nack, &two));
    try std.testing.expect(asksForKeyPicture(&(receiver_report ++ nack ++ picture_loss)));
    try std.testing.expect(!asksForKeyPicture(&(receiver_report ++ nack)));
    try std.testing.expect(!asksForKeyPicture(picture_loss[0..10]));
    try std.testing.expect(isRtcp(&nack));
    try std.testing.expect(!isRtcp(&.{ 0x80, 96, 0, 1, 0, 0, 0, 0 }));
}

test "Resend finds a packet by its sequence number until it is overwritten" {
    var r: Resend = .{};
    var packet = [_]u8{ 0x80, 96, 0x12, 0x34 } ++ @as([20]u8, @splat(7));
    try std.testing.expectEqual(null, r.find(0x1234));
    r.store(&packet);
    try std.testing.expectEqualSlices(u8, &packet, r.find(0x1234).?);
    try std.testing.expectEqual(null, r.find(0x1134));
    packet[2] = 0x13;
    r.store(&packet);
    try std.testing.expectEqual(null, r.find(0x1234));
    try std.testing.expect(r.find(0x1334) != null);
    r.store(packet[0..8]);
    try std.testing.expect(r.find(0x1334) != null);
    r.clear();
    try std.testing.expectEqual(null, r.find(0x1334));
}
