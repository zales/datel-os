//! STUN as an ICE-lite agent needs it (RFC 8445 2.5, RFC 8489): answer the
//! browser's connectivity checks. Nothing is ever asked of the browser, so its
//! candidates and its password are not needed.
const std = @import("std");
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

const magic_cookie = [4]u8{ 0x21, 0x12, 0xA4, 0x42 };
const header_len = 20;
const binding_request = 0x0001;
const binding_success = 0x0101;
const attr_username = 0x0006;
const attr_message_integrity = 0x0008;
const attr_xor_mapped_address = 0x0020;
const attr_use_candidate = 0x0025;
const attr_fingerprint = 0x8028;

pub const response_len = header_len + 12 + 24 + 8;

/// Datagrams on a WebRTC port are told apart by their first byte (RFC 7983);
/// STUN's is 0 to 3, and it carries the magic cookie.
pub fn isStun(datagram: []const u8) bool {
    return datagram.len >= header_len and datagram[0] < 4 and std.mem.eql(u8, datagram[4..8], &magic_cookie);
}

pub const Request = struct {
    transaction: [12]u8,
    /// the browser has chosen this path for the media
    use_candidate: bool,
};

fn integrity(message: []const u8, length_field: u16, key: []const u8) [20]u8 {
    // The length that is signed counts the integrity attribute itself and
    // nothing after it.
    var mac = HmacSha1.init(key);
    var length: [2]u8 = undefined;
    std.mem.writeInt(u16, &length, length_field, .big);
    mac.update(message[0..2]);
    mac.update(&length);
    mac.update(message[4..]);
    var out: [20]u8 = undefined;
    mac.final(&out);
    return out;
}

/// A Binding request that names `ufrag` as its receiver and is signed with
/// `pwd`; null for anything else.
pub fn parseBindingRequest(message: []const u8, ufrag: []const u8, pwd: []const u8) ?Request {
    if (!isStun(message)) return null;
    if (std.mem.readInt(u16, message[0..2], .big) != binding_request) return null;
    if (std.mem.readInt(u16, message[2..4], .big) != message.len - header_len or message.len % 4 != 0) return null;

    var request: Request = .{ .transaction = message[8..20].*, .use_candidate = false };
    var for_us = false;
    var at: usize = header_len;
    while (at + 4 <= message.len) {
        const kind = std.mem.readInt(u16, message[at..][0..2], .big);
        const len = std.mem.readInt(u16, message[at + 2 ..][0..2], .big);
        const value_at = at + 4;
        if (value_at + len > message.len) return null;
        const value = message[value_at..][0..len];
        switch (kind) {
            // "<receiver's ufrag>:<sender's ufrag>"
            attr_username => for_us = value.len > ufrag.len and std.mem.startsWith(u8, value, ufrag) and value[ufrag.len] == ':',
            attr_use_candidate => request.use_candidate = true,
            attr_message_integrity => {
                if (len != 20 or !for_us) return null;
                const expected = integrity(message[0..at], @intCast(value_at + 20 - header_len), pwd);
                return if (std.crypto.timing_safe.eql([20]u8, expected, value[0..20].*)) request else null;
            },
            else => {},
        }
        at = value_at + (@as(usize, len) + 3) / 4 * 4;
    }
    return null; // unsigned
}

/// The success response to `request`, telling the sender the address its
/// request came from, signed with `pwd`.
pub fn bindingResponse(request: Request, addr: [4]u8, port: u16, pwd: []const u8, out: *[response_len]u8) void {
    std.mem.writeInt(u16, out[0..2], binding_success, .big);
    out[4..8].* = magic_cookie;
    out[8..20].* = request.transaction;

    // XOR-MAPPED-ADDRESS: port and address xored with the cookie
    var at: usize = header_len;
    std.mem.writeInt(u16, out[at..][0..2], attr_xor_mapped_address, .big);
    std.mem.writeInt(u16, out[at + 2 ..][0..2], 8, .big);
    out[at + 4] = 0;
    out[at + 5] = 1; // IPv4
    std.mem.writeInt(u16, out[at + 6 ..][0..2], port ^ 0x2112, .big);
    for (addr, magic_cookie, 0..) |a, m, i| out[at + 8 + i] = a ^ m;
    at += 12;

    std.mem.writeInt(u16, out[at..][0..2], attr_message_integrity, .big);
    std.mem.writeInt(u16, out[at + 2 ..][0..2], 20, .big);
    out[at + 4 ..][0..20].* = integrity(out[0..at], @intCast(at + 24 - header_len), pwd);
    at += 24;

    // FINGERPRINT covers everything before it, with the final length in place
    std.mem.writeInt(u16, out[2..4], response_len - header_len, .big);
    std.mem.writeInt(u16, out[at..][0..2], attr_fingerprint, .big);
    std.mem.writeInt(u16, out[at + 2 ..][0..2], 4, .big);
    std.mem.writeInt(u32, out[at + 4 ..][0..4], std.hash.Crc32.hash(out[0..at]) ^ 0x5354554e, .big);
}

// ---- tests ----

/// RFC 5769 2.1: a request with USERNAME "evtj:h6vY" and password
/// "VOkJxbRl1RmTxUk/WvJxBt", followed by a FINGERPRINT.
const rfc5769_request = [_]u8{
    0x00, 0x01, 0x00, 0x58, 0x21, 0x12, 0xa4, 0x42, 0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86,
    0xfa, 0x87, 0xdf, 0xae, 0x80, 0x22, 0x00, 0x10, 0x53, 0x54, 0x55, 0x4e, 0x20, 0x74, 0x65, 0x73,
    0x74, 0x20, 0x63, 0x6c, 0x69, 0x65, 0x6e, 0x74, 0x00, 0x24, 0x00, 0x04, 0x6e, 0x00, 0x01, 0xff,
    0x80, 0x29, 0x00, 0x08, 0x93, 0x2f, 0xf9, 0xb1, 0x51, 0x26, 0x3b, 0x36, 0x00, 0x06, 0x00, 0x09,
    0x65, 0x76, 0x74, 0x6a, 0x3a, 0x68, 0x36, 0x76, 0x59, 0x20, 0x20, 0x20, 0x00, 0x08, 0x00, 0x14,
    0x9a, 0xea, 0xa7, 0x0c, 0xbf, 0xd8, 0xcb, 0x56, 0x78, 0x1e, 0xf2, 0xb5, 0xb2, 0xd3, 0xf2, 0x49,
    0xc1, 0xb5, 0x71, 0xa2, 0x80, 0x28, 0x00, 0x04, 0xe5, 0x7a, 0x3b, 0xcf,
};
const rfc5769_password = "VOkJxbRl1RmTxUk/WvJxBt";

test "the RFC 5769 sample request is accepted with its password only" {
    const request = parseBindingRequest(&rfc5769_request, "evtj", rfc5769_password).?;
    try std.testing.expectEqualSlices(u8, rfc5769_request[8..20], &request.transaction);
    try std.testing.expect(!request.use_candidate);

    try std.testing.expectEqual(null, parseBindingRequest(&rfc5769_request, "evtj", "another password"));
    try std.testing.expectEqual(null, parseBindingRequest(&rfc5769_request, "evt", rfc5769_password));
    try std.testing.expectEqual(null, parseBindingRequest(&rfc5769_request, "other", rfc5769_password));
    var changed = rfc5769_request;
    changed[30] ^= 1;
    try std.testing.expectEqual(null, parseBindingRequest(&changed, "evtj", rfc5769_password));
    try std.testing.expectEqual(null, parseBindingRequest(rfc5769_request[0..60], "evtj", rfc5769_password));
}

test "a request without a signature, or cut short, is refused" {
    const unsigned = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42 } ++ @as([12]u8, @splat(7));
    try std.testing.expect(isStun(&unsigned));
    try std.testing.expectEqual(null, parseBindingRequest(&unsigned, "evtj", rfc5769_password));
    // an attribute that claims more bytes than there are
    const overlong = [_]u8{ 0x00, 0x01, 0x00, 0x04, 0x21, 0x12, 0xa4, 0x42 } ++ @as([12]u8, @splat(7)) ++ [_]u8{ 0x00, 0x06, 0xff, 0xff };
    try std.testing.expectEqual(null, parseBindingRequest(&overlong, "evtj", rfc5769_password));
    try std.testing.expect(!isStun(&[_]u8{ 0x80, 0x60, 0, 1 }));
    try std.testing.expect(!isStun(&(@as([20]u8, @splat(0)))));
}

test "the response has the RFC 5769 layout and verifies" {
    // RFC 5769 2.2 answers the request above for 192.0.2.1:32853. Its
    // SOFTWARE attribute is left out here, so only the parts that do not
    // depend on it are compared with the RFC: header and mapped address.
    const request = parseBindingRequest(&rfc5769_request, "evtj", rfc5769_password).?;
    var out: [response_len]u8 = undefined;
    bindingResponse(request, .{ 192, 0, 2, 1 }, 32853, rfc5769_password, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 0x00, 0x2c, 0x21, 0x12, 0xa4, 0x42 }, out[0..8]);
    try std.testing.expectEqualSlices(u8, rfc5769_request[8..20], out[8..20]);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43 }, out[20..32]);
    // signature and checksum the way a receiver recomputes them
    try std.testing.expectEqualSlices(u8, &integrity(out[0..32], 12 + 24, rfc5769_password), out[36..56]);
    try std.testing.expectEqual(std.hash.Crc32.hash(out[0..56]) ^ 0x5354554e, std.mem.readInt(u32, out[60..64], .big));
}
