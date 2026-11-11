//! SRTP and SRTCP with the profile every browser offers,
//! SRTP_AES128_CM_HMAC_SHA1_80 (RFC 3711): AES-128 in counter mode, and an
//! HMAC-SHA1 tag cut to ten bytes.
const std = @import("std");
const Aes128 = std.crypto.core.aes.Aes128;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

pub const tag_len = 10;
/// what protectRtp() adds to a packet
pub const rtp_overhead = tag_len;

pub const Kind = enum(u8) {
    rtp = 0,
    /// SRTCP derives its keys with labels three higher
    rtcp = 3,
};

fn counterMode(aes: anytype, iv: [16]u8, data: []u8) void {
    // The last two bytes of the IV are zero and count the blocks.
    var counter = iv;
    var block: usize = 0;
    var at: usize = 0;
    while (at < data.len) : (block += 1) {
        std.mem.writeInt(u16, counter[14..16], @intCast(block), .big);
        var keystream: [16]u8 = undefined;
        aes.encrypt(&keystream, &counter);
        const n = @min(16, data.len - at);
        for (data[at..][0..n], keystream[0..n]) |*byte, k| byte.* ^= k;
        at += n;
    }
}

/// RFC 3711 4.3.1 with a key derivation rate of zero: the session key is
/// keystream under the master key, at an IV made of the salt and the label.
fn derive(master_key: [16]u8, master_salt: [14]u8, label: u8, out: []u8) void {
    var iv: [16]u8 = master_salt ++ [2]u8{ 0, 0 };
    iv[7] ^= label;
    @memset(out, 0);
    counterMode(Aes128.initEnc(master_key), iv, out);
}

/// One direction of one stream kind: the session keys of a master key.
pub const Context = struct {
    cipher: @TypeOf(Aes128.initEnc(@splat(0))),
    salt: [14]u8,
    auth_key: [20]u8,

    pub fn init(master_key: [16]u8, master_salt: [14]u8, kind: Kind) Context {
        var cipher_key: [16]u8 = undefined;
        var c: Context = undefined;
        derive(master_key, master_salt, @intFromEnum(kind), &cipher_key);
        derive(master_key, master_salt, @intFromEnum(kind) + 1, &c.auth_key);
        derive(master_key, master_salt, @intFromEnum(kind) + 2, &c.salt);
        c.cipher = Aes128.initEnc(cipher_key);
        return c;
    }

    /// RFC 3711 4.1.1: salt, source and packet index, laid over each other.
    fn iv(c: *const Context, ssrc: [4]u8, index: u48) [16]u8 {
        var out: [16]u8 = c.salt ++ [2]u8{ 0, 0 };
        for (out[4..8], ssrc) |*byte, s| byte.* ^= s;
        var index_bytes: [6]u8 = undefined;
        std.mem.writeInt(u48, &index_bytes, index, .big);
        for (out[8..14], index_bytes) |*byte, i| byte.* ^= i;
        return out;
    }

    fn tag(c: *const Context, packet: []const u8, trailer: [4]u8) [tag_len]u8 {
        var mac = HmacSha1.init(&c.auth_key);
        mac.update(packet);
        mac.update(&trailer);
        var full: [20]u8 = undefined;
        mac.final(&full);
        return full[0..tag_len].*;
    }

    /// Encrypts the payload of the RTP packet in buf[0..len], which has a
    /// plain twelve byte header, and appends the tag. `roc` counts how often
    /// this stream's sequence number has wrapped. Returns the new length;
    /// buf must have room for `rtp_overhead` more bytes.
    pub fn protectRtp(c: *const Context, buf: []u8, len: usize, roc: u32) usize {
        std.debug.assert(len >= 12 and buf.len >= len + rtp_overhead);
        const seq = std.mem.readInt(u16, buf[2..4], .big);
        counterMode(c.cipher, c.iv(buf[8..12].*, @as(u48, roc) << 16 | seq), buf[12..len]);
        var roc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &roc_bytes, roc, .big);
        buf[len..][0..tag_len].* = c.tag(buf[0..len], roc_bytes);
        return len + tag_len;
    }

    /// Checks and decrypts an SRTCP packet in place; the plain RTCP packet,
    /// or null when its tag is wrong or it is too short. Replays are not
    /// tracked: all that is done with a report is to send packets again.
    pub fn unprotectRtcp(c: *const Context, packet: []u8) ?[]u8 {
        // header and sender (8), E flag and index (4), tag
        if (packet.len < 8 + 4 + tag_len) return null;
        const body_end = packet.len - 4 - tag_len;
        const trailer = packet[body_end..][0..4].*;
        const expected = c.tag(packet[0..body_end], trailer);
        if (!std.crypto.timing_safe.eql([tag_len]u8, expected, packet[body_end + 4 ..][0..tag_len].*)) return null;
        const word = std.mem.readInt(u32, &trailer, .big);
        const encrypted = word >> 31 == 1;
        if (encrypted) counterMode(c.cipher, c.iv(packet[4..8].*, word & 0x7fff_ffff), packet[8..body_end]);
        return packet[0..body_end];
    }

    /// The reverse of unprotectRtcp, for tests.
    fn protectRtcp(c: *const Context, buf: []u8, len: usize, index: u31) usize {
        counterMode(c.cipher, c.iv(buf[4..8].*, index), buf[8..len]);
        std.mem.writeInt(u32, buf[len..][0..4], @as(u32, index) | 1 << 31, .big);
        buf[len + 4 ..][0..tag_len].* = c.tag(buf[0..len], buf[len..][0..4].*);
        return len + 4 + tag_len;
    }
};

// ---- tests ----

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "AES counter mode keystream, RFC 3711 B.2" {
    var keystream: [48]u8 = @splat(0);
    const iv = hex("F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000");
    counterMode(Aes128.initEnc(hex("2B7E151628AED2A6ABF7158809CF4F3C")), iv, &keystream);
    try std.testing.expectEqualSlices(u8, &hex("E03EAD0935C95E80E166B16DD92B4EB4" ++ "D23513162B02D0F72A43A2FE4A5F97AB" ++ "41E95B3BB0A2E8DD477901E4FCA894C0"), &keystream);
}

test "key derivation, RFC 3711 B.3" {
    const key = hex("E1F97A0D3E018BE0D64FA32C06DE4139");
    const salt = hex("0EC675AD498AFEEBB6960B3AABE6");
    var cipher_key: [16]u8 = undefined;
    derive(key, salt, 0, &cipher_key);
    try std.testing.expectEqualSlices(u8, &hex("C61E7A93744F39EE10734AFE3FF7A087"), &cipher_key);
    const c = Context.init(key, salt, .rtp);
    try std.testing.expectEqualSlices(u8, &hex("30CBBC08863D8C85D49DB34A9AE1"), &c.salt);
    try std.testing.expectEqualSlices(u8, &hex("CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"), &c.auth_key);
}

test "protectRtp leaves the header, changes the payload, and depends on the rollover count" {
    const c = Context.init(@splat(1), @splat(2), .rtp);
    const plain = [_]u8{ 0x80, 96, 0x12, 0x34, 0, 0, 0, 9, 1, 2, 3, 4 } ++ @as([40]u8, @splat(0x55));
    var a: [plain.len + rtp_overhead]u8 = undefined;
    var b = a;
    a[0..plain.len].* = plain;
    b[0..plain.len].* = plain;
    try std.testing.expectEqual(a.len, c.protectRtp(&a, plain.len, 0));
    _ = c.protectRtp(&b, plain.len, 1);
    try std.testing.expectEqualSlices(u8, plain[0..12], a[0..12]);
    try std.testing.expect(!std.mem.eql(u8, plain[12..], a[12..plain.len]));
    try std.testing.expect(!std.mem.eql(u8, a[12..], b[12..]));
    // counter mode: encrypting again restores the payload
    counterMode(c.cipher, c.iv(a[8..12].*, 0x1234), a[12..plain.len]);
    try std.testing.expectEqualSlices(u8, &plain, a[0..plain.len]);
}

test "unprotectRtcp undoes protectRtcp and refuses a changed packet" {
    const c = Context.init(@splat(3), @splat(4), .rtcp);
    const plain = [_]u8{ 0x81, 205, 0, 3, 0, 0, 0, 1, 0, 0, 0, 2, 0, 100, 0, 0 };
    var buf: [plain.len + 14]u8 = undefined;
    buf[0..plain.len].* = plain;
    try std.testing.expectEqual(buf.len, c.protectRtcp(&buf, plain.len, 77));
    try std.testing.expectEqualSlices(u8, plain[0..8], buf[0..8]);
    try std.testing.expect(!std.mem.eql(u8, plain[8..], buf[8..plain.len]));
    var copy = buf;
    try std.testing.expectEqualSlices(u8, &plain, c.unprotectRtcp(&copy).?);
    copy = buf;
    copy[9] ^= 1;
    try std.testing.expectEqual(null, c.unprotectRtcp(&copy));
    copy = buf;
    try std.testing.expectEqual(null, c.unprotectRtcp(copy[0..20]));
    // keys for RTP do not open RTCP
    copy = buf;
    try std.testing.expectEqual(null, Context.init(@splat(3), @splat(4), .rtp).unprotectRtcp(&copy));
}
