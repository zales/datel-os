//! An MP4 file around one H.264 stream of constant frame rate (ISO 14496-12
//! and -15): what a timelapse needs. The index (moov) comes before the
//! pictures (mdat), so a browser can start playing while it still downloads.
const std = @import("std");
const NalIterator = @import("rtp.zig").NalIterator;

/// Media time runs in units of 1/90000 s, as RTP's does: every usual frame
/// rate divides it.
pub const timescale = 90000;

// ---- H.264 ----

/// Reads the bits of a NAL unit, skipping the emulation prevention bytes
/// (the 03 in 00 00 03) that keep start codes out of the payload.
const BitReader = struct {
    data: []const u8,
    byte: usize = 0,
    bit: u3 = 0,
    zeros: u8 = 0,

    fn readBit(r: *BitReader) !u1 {
        if (r.bit == 0 and r.byte < r.data.len and r.zeros >= 2 and r.data[r.byte] == 3) {
            r.byte += 1;
            r.zeros = 0;
        }
        if (r.byte >= r.data.len) return error.EndOfData;
        const value: u1 = @truncate(r.data[r.byte] >> (7 - r.bit));
        if (r.bit == 7) {
            r.zeros = if (r.data[r.byte] == 0) r.zeros + 1 else 0;
            r.byte += 1;
            r.bit = 0;
        } else r.bit += 1;
        return value;
    }

    fn bits(r: *BitReader, count: u6) !u32 {
        var value: u32 = 0;
        for (0..count) |_| value = value << 1 | try r.readBit();
        return value;
    }

    /// an Exp-Golomb code, ue(v)
    fn unsigned(r: *BitReader) !u32 {
        var leading: u6 = 0;
        while (try r.readBit() == 0) {
            leading += 1;
            if (leading > 31) return error.BadCode;
        }
        return (@as(u32, 1) << @intCast(leading)) - 1 + try r.bits(leading);
    }

    /// se(v)
    fn signed(r: *BitReader) !i32 {
        const code = try r.unsigned();
        const half: i32 = @intCast((code + 1) / 2);
        return if (code % 2 == 1) half else -half;
    }
};

pub const Size = struct { width: u16, height: u16 };

/// The picture size a sequence parameter set declares (ITU-T H.264 7.3.2.1.1).
pub fn pictureSize(sps: []const u8) !Size {
    if (sps.len < 4 or sps[0] & 0x1f != 7) return error.NotSps;
    const profile = sps[1];
    var r: BitReader = .{ .data = sps[4..] }; // behind profile, constraints and level
    _ = try r.unsigned(); // seq_parameter_set_id
    var chroma_format: u32 = 1;
    const high_profiles = [_]u8{ 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 };
    if (std.mem.findScalar(u8, &high_profiles, profile) != null) {
        chroma_format = try r.unsigned();
        if (chroma_format == 3) _ = try r.readBit();
        _ = try r.unsigned(); // bit_depth_luma_minus8
        _ = try r.unsigned(); // bit_depth_chroma_minus8
        _ = try r.readBit();
        if (try r.readBit() == 1) { // scaling matrices
            const lists: usize = if (chroma_format == 3) 12 else 8;
            for (0..lists) |i| {
                if (try r.readBit() == 0) continue;
                var last: i32 = 8;
                var next: i32 = 8;
                for (0..if (i < 6) @as(usize, 16) else 64) |_| {
                    if (next != 0) next = @mod(last + try r.signed() + 256, 256);
                    if (next != 0) last = next;
                }
            }
        }
    }
    _ = try r.unsigned(); // log2_max_frame_num_minus4
    const order_type = try r.unsigned();
    if (order_type == 0) {
        _ = try r.unsigned();
    } else if (order_type == 1) {
        _ = try r.readBit();
        _ = try r.signed();
        _ = try r.signed();
        const cycle = try r.unsigned();
        if (cycle > 255) return error.BadCode;
        for (0..cycle) |_| _ = try r.signed();
    }
    _ = try r.unsigned(); // max_num_ref_frames
    _ = try r.readBit();
    const width_mbs = try r.unsigned() + 1;
    const height_units = try r.unsigned() + 1;
    const frames_only: u32 = try r.readBit();
    if (frames_only == 0) _ = try r.readBit();
    _ = try r.readBit();
    var crop: [4]u32 = @splat(0); // left, right, top, bottom
    if (try r.readBit() == 1) {
        for (&crop) |*c| c.* = try r.unsigned();
    }
    if (width_mbs > 1024 or height_units > 1024) return error.BadCode;
    // cropping counts chroma samples: two luma samples each way for 4:2:0
    const unit_x: u32 = if (chroma_format == 1 or chroma_format == 2) 2 else 1;
    const unit_y: u32 = (if (chroma_format == 1) @as(u32, 2) else 1) * (2 - frames_only);
    const width = width_mbs * 16;
    const height = (2 - frames_only) * height_units * 16;
    const crop_x = unit_x * (crop[0] + crop[1]);
    const crop_y = unit_y * (crop[2] + crop[3]);
    if (crop_x >= width or crop_y >= height) return error.BadCode;
    return .{ .width = @intCast(width - crop_x), .height = @intCast(height - crop_y) };
}

/// How many bytes a picture takes as an MP4 sample: its NAL units with a
/// four byte length each. Parameter sets and delimiters are left out (the
/// index has the former), and so is filler.
pub fn sampleSize(picture: []const u8) usize {
    var size: usize = 0;
    var nals: NalIterator = .{ .data = picture };
    while (nals.next()) |nal| {
        if (inSample(nal)) size += 4 + nal.len;
    }
    return size;
}

fn inSample(nal: []const u8) bool {
    return switch (nal[0] & 0x1f) {
        7, 8, 9, 12 => false,
        else => true,
    };
}

/// Writes that sample; `out` holds at least sampleSize() bytes.
pub fn writeSample(picture: []const u8, out: []u8) void {
    var at: usize = 0;
    var nals: NalIterator = .{ .data = picture };
    while (nals.next()) |nal| {
        if (!inSample(nal)) continue;
        std.mem.writeInt(u32, out[at..][0..4], @intCast(nal.len), .big);
        @memcpy(out[at + 4 ..][0..nal.len], nal);
        at += 4 + nal.len;
    }
}

// ---- boxes ----

const Boxes = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn bytes(b: *Boxes, data: []const u8) void {
        if (b.len + data.len > b.buf.len) {
            b.overflow = true;
            return;
        }
        @memcpy(b.buf[b.len..][0..data.len], data);
        b.len += data.len;
    }

    fn int(b: *Boxes, comptime T: type, value: T) void {
        var raw: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &raw, value, .big);
        b.bytes(&raw);
    }

    fn zeros(b: *Boxes, count: usize) void {
        for (0..count) |_| b.bytes(&.{0});
    }

    /// Starts a box; end() fills in its size.
    fn begin(b: *Boxes, name: *const [4]u8) usize {
        const at = b.len;
        b.int(u32, 0);
        b.bytes(name);
        return at;
    }

    /// A box with a version and flags word.
    fn beginFull(b: *Boxes, name: *const [4]u8, flags: u32) usize {
        const at = b.begin(name);
        b.int(u32, flags);
        return at;
    }

    fn end(b: *Boxes, at: usize) void {
        if (b.overflow) return;
        std.mem.writeInt(u32, b.buf[at..][0..4], @intCast(b.len - at), .big);
    }
};

pub const Video = struct {
    sps: []const u8,
    pps: []const u8,
    /// frames per second
    rate: u32,
    /// bytes of every sample, in order
    sizes: []const u32,
    /// numbers of the key pictures, counted from 1, ascending
    key_samples: []const u32,
};

const file_type = [_]u8{ 0, 0, 0, 28 } ++ "ftyp".* ++ "isom".* ++ [_]u8{ 0, 0, 2, 0 } ++ "isomiso2avc1".*;

/// Everything in front of the samples: file type, the whole index, and the
/// header of the box the samples follow in. Null when `out` is too small or
/// the stream cannot be described (too long, odd parameter sets).
pub fn header(video: Video, out: []u8) ?[]u8 {
    const size = pictureSize(video.sps) catch return null;
    if (video.rate == 0 or video.rate > timescale or video.sizes.len == 0) return null;
    if (video.sps.len > 0xffff or video.pps.len > 0xffff) return null;
    const delta = timescale / video.rate;
    var total: u64 = 0;
    for (video.sizes) |s| total += s;
    const duration = @as(u64, video.sizes.len) * delta;
    // 32 bit sizes and times: four gigabytes, thirteen hours
    if (total + 8 > 0xffff_ffff or duration > 0xffff_ffff) return null;
    const millis: u32 = @intCast(duration * 1000 / timescale);
    const identity = [_]u32{ 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000 };

    var b: Boxes = .{ .buf = out };
    b.bytes(&file_type);
    const moov = b.begin("moov");
    {
        const mvhd = b.beginFull("mvhd", 0);
        b.zeros(8); // made and changed: unknown
        b.int(u32, 1000);
        b.int(u32, millis);
        b.int(u32, 0x10000); // speed 1
        b.int(u16, 0x100); // volume 1
        b.zeros(10);
        for (identity) |m| b.int(u32, m);
        b.zeros(24);
        b.int(u32, 2); // the next track's number
        b.end(mvhd);

        const trak = b.begin("trak");
        const tkhd = b.beginFull("tkhd", 3); // enabled, in the movie
        b.zeros(8);
        b.int(u32, 1); // track number
        b.zeros(4);
        b.int(u32, millis);
        b.zeros(16);
        for (identity) |m| b.int(u32, m);
        b.int(u32, @as(u32, size.width) << 16);
        b.int(u32, @as(u32, size.height) << 16);
        b.end(tkhd);

        const mdia = b.begin("mdia");
        const mdhd = b.beginFull("mdhd", 0);
        b.zeros(8);
        b.int(u32, timescale);
        b.int(u32, @intCast(duration));
        b.int(u16, 0x55c4); // language: undetermined
        b.zeros(2);
        b.end(mdhd);
        const hdlr = b.beginFull("hdlr", 0);
        b.zeros(4);
        b.bytes("vide");
        b.zeros(12);
        b.bytes("VideoHandler\x00");
        b.end(hdlr);

        const minf = b.begin("minf");
        const vmhd = b.beginFull("vmhd", 1);
        b.zeros(8);
        b.end(vmhd);
        const dinf = b.begin("dinf");
        const dref = b.beginFull("dref", 0);
        b.int(u32, 1);
        const url = b.beginFull("url ", 1); // the media is in this file
        b.end(url);
        b.end(dref);
        b.end(dinf);

        const stbl = b.begin("stbl");
        const stsd = b.beginFull("stsd", 0);
        b.int(u32, 1);
        const avc1 = b.begin("avc1");
        b.zeros(6);
        b.int(u16, 1); // data reference
        b.zeros(16);
        b.int(u16, size.width);
        b.int(u16, size.height);
        b.int(u32, 0x480000); // 72 dpi
        b.int(u32, 0x480000);
        b.zeros(4);
        b.int(u16, 1); // one frame per sample
        b.zeros(32); // no encoder name
        b.int(u16, 24); // colour, no alpha
        b.int(u16, 0xffff);
        const avcc = b.begin("avcC");
        // profile and level from the SPS; four byte NAL lengths; one SPS, one PPS
        b.bytes(&.{ 1, video.sps[1], video.sps[2], video.sps[3], 0xff, 0xe1 });
        b.int(u16, @intCast(video.sps.len));
        b.bytes(video.sps);
        b.bytes(&.{1});
        b.int(u16, @intCast(video.pps.len));
        b.bytes(video.pps);
        b.end(avcc);
        b.end(avc1);
        b.end(stsd);

        const stts = b.beginFull("stts", 0); // every sample lasts the same
        b.int(u32, 1);
        b.int(u32, @intCast(video.sizes.len));
        b.int(u32, delta);
        b.end(stts);
        const stss = b.beginFull("stss", 0); // where a player can start
        b.int(u32, @intCast(video.key_samples.len));
        for (video.key_samples) |k| b.int(u32, k);
        b.end(stss);
        const stsc = b.beginFull("stsc", 0); // all samples in one chunk
        b.int(u32, 1);
        b.int(u32, 1);
        b.int(u32, @intCast(video.sizes.len));
        b.int(u32, 1);
        b.end(stsc);
        const stsz = b.beginFull("stsz", 0);
        b.int(u32, 0);
        b.int(u32, @intCast(video.sizes.len));
        for (video.sizes) |s| b.int(u32, s);
        b.end(stsz);
        const stco = b.beginFull("stco", 0); // where that chunk starts
        b.int(u32, 1);
        const chunk_offset_at = b.len;
        b.int(u32, 0);
        b.end(stco);
        b.end(stbl);
        b.end(minf);
        b.end(mdia);
        b.end(trak);
        b.end(moov);

        b.int(u32, @intCast(total + 8));
        b.bytes("mdat");
        if (b.overflow) return null;
        std.mem.writeInt(u32, out[chunk_offset_at..][0..4], @intCast(b.len), .big);
    }
    return out[0..b.len];
}

// ---- tests ----

/// the K1 encoder's parameter set: Main profile, level 3.1, 1280x720
const k1_sps = [_]u8{ 0x67, 0x4d, 0x40, 0x1f, 0xda, 0x01, 0x40, 0x16, 0xe4 };

test "pictureSize reads the K1's parameter set and a cropped one" {
    try std.testing.expectEqual(Size{ .width = 1280, .height = 720 }, try pictureSize(&k1_sps));
    // 1920x1080 is coded as 1088 lines with eight cropped: High profile,
    // x264's parameter set for it
    const full_hd = [_]u8{ 0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40, 0x78, 0x02, 0x27, 0xe5, 0xc0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0xf0, 0x3c, 0x60, 0xc6, 0x58 };
    try std.testing.expectEqual(Size{ .width = 1920, .height = 1080 }, try pictureSize(&full_hd));
    try std.testing.expectError(error.NotSps, pictureSize(&.{ 0x68, 1, 2, 3 }));
    try std.testing.expectError(error.EndOfData, pictureSize(k1_sps[0..6]));
}

test "BitReader skips emulation prevention bytes" {
    var r: BitReader = .{ .data = &.{ 0x00, 0x00, 0x03, 0x01, 0xff } };
    try std.testing.expectEqual(0, try r.bits(16));
    try std.testing.expectEqual(0x01, try r.bits(8)); // the 03 is not data
    try std.testing.expectEqual(0xff, try r.bits(8));
    try std.testing.expectError(error.EndOfData, r.readBit());
    var codes: BitReader = .{ .data = &.{0b1_010_011_0, 0b0100_0010, 0b1_0000000} };
    try std.testing.expectEqual(0, try codes.unsigned());
    try std.testing.expectEqual(1, try codes.unsigned());
    try std.testing.expectEqual(2, try codes.unsigned());
    try std.testing.expectEqual(3, try codes.unsigned());
    try std.testing.expectEqual(-2, try codes.signed()); // code 4
}

test "a sample keeps slices and drops parameter sets, delimiters and filler" {
    const picture = [_]u8{ 0, 0, 0, 1, 0x09, 0xf0 } ++ [_]u8{ 0, 0, 0, 1 } ++ k1_sps ++
        [_]u8{ 0, 0, 0, 1, 0x68, 0xee, 0x38, 0x80 } ++ [_]u8{ 0, 0, 1, 0x0c, 0xff, 0x80 } ++
        [_]u8{ 0, 0, 1, 0x06, 5, 5 } ++ [_]u8{ 0, 0, 1, 0x65, 1, 2, 3 };
    try std.testing.expectEqual(4 + 3 + 4 + 4, sampleSize(&picture));
    var out: [15]u8 = undefined;
    writeSample(&picture, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 3, 0x06, 5, 5, 0, 0, 0, 4, 0x65, 1, 2, 3 }, &out);
}

fn findBox(data: []const u8, comptime path: []const []const u8) ?[]const u8 {
    var inside = data;
    inline for (path) |name| {
        var at: usize = 0;
        const found = while (at + 8 <= inside.len) {
            const size = std.mem.readInt(u32, inside[at..][0..4], .big);
            if (size < 8 or at + size > inside.len) return null;
            if (std.mem.eql(u8, inside[at + 4 ..][0..4], name)) break inside[at + 8 .. at + size];
            at += size;
        } else return null;
        inside = found;
    }
    return inside;
}

test "header: boxes nest, sizes add up and the chunk offset points behind it" {
    const pps = [_]u8{ 0x68, 0xee, 0x38, 0x80 };
    var out: [1024]u8 = undefined;
    const head = header(.{ .sps = &k1_sps, .pps = &pps, .rate = 30, .sizes = &.{ 100, 20, 30 }, .key_samples = &.{1} }, &out).?;
    try std.testing.expectEqualSlices(u8, &file_type, head[0..28]);
    // the last eight bytes open the box that holds the samples
    try std.testing.expectEqual(150 + 8, std.mem.readInt(u32, head[head.len - 8 ..][0..4], .big));
    try std.testing.expectEqualStrings("mdat", head[head.len - 4 ..]);
    const moov = head[28 .. head.len - 8];
    try std.testing.expectEqual(moov.len, std.mem.readInt(u32, moov[0..4], .big));

    const stbl = [_][]const u8{ "moov", "trak", "mdia", "minf", "stbl" };
    const stco = findBox(head, &(stbl ++ [_][]const u8{"stco"})).?;
    try std.testing.expectEqual(head.len, std.mem.readInt(u32, stco[8..12], .big));
    const stsz = findBox(head, &(stbl ++ [_][]const u8{"stsz"})).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 100, 0, 0, 0, 20, 0, 0, 0, 30 }, stsz);
    const stts = findBox(head, &(stbl ++ [_][]const u8{"stts"})).?;
    try std.testing.expectEqual(3000, std.mem.readInt(u32, stts[12..16], .big)); // 1/30 s
    const mdhd = findBox(head, &.{ "moov", "trak", "mdia", "mdhd" }).?;
    try std.testing.expectEqual(9000, std.mem.readInt(u32, mdhd[16..20], .big)); // three frames
    const tkhd = findBox(head, &.{ "moov", "trak", "tkhd" }).?;
    try std.testing.expectEqual(1280 << 16, std.mem.readInt(u32, tkhd[tkhd.len - 8 ..][0..4], .big));
    try std.testing.expectEqual(720 << 16, std.mem.readInt(u32, tkhd[tkhd.len - 4 ..][0..4], .big));
    // the decoder configuration sits at the end of the sample description
    const stsd = findBox(head, &(stbl ++ [_][]const u8{"stsd"})).?;
    try std.testing.expect(std.mem.endsWith(u8, stsd, &(.{ 1, 0x4d, 0x40, 0x1f, 0xff, 0xe1, 0, 9 } ++ k1_sps ++ .{ 1, 0, 4 } ++ pps)));
}

test "header refuses what it cannot describe" {
    const pps = [_]u8{ 0x68, 0xee, 0x38, 0x80 };
    var out: [1024]u8 = undefined;
    var small: [200]u8 = undefined;
    const ok: Video = .{ .sps = &k1_sps, .pps = &pps, .rate = 30, .sizes = &.{100}, .key_samples = &.{1} };
    try std.testing.expect(header(ok, &out) != null);
    try std.testing.expectEqual(null, header(ok, &small));
    var v = ok;
    v.rate = 0;
    try std.testing.expectEqual(null, header(v, &out));
    v = ok;
    v.sizes = &.{};
    try std.testing.expectEqual(null, header(v, &out));
    v = ok;
    v.sizes = &.{ 0xffff_fff0, 0x20 }; // more than a 32 bit box holds
    try std.testing.expectEqual(null, header(v, &out));
    v = ok;
    v.sps = &pps;
    try std.testing.expectEqual(null, header(v, &out));
}
