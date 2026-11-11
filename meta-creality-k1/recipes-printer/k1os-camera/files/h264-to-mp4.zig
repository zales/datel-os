//! h264-to-mp4 <frames per second> <in.h264> <out.mp4>
//!
//! Wraps a raw H.264 stream (Annex B, as the K1's encoder writes it) into an
//! MP4 file of constant frame rate: what ffmpeg did for the timelapse with
//! "-r N -i in.h264 -c:v copy -movflags +faststart out.mp4".
//!
//! The input is read twice, once to measure every picture for the index and
//! once to copy them, so a video of any length needs the same few megabytes
//! of memory.
const std = @import("std");
const rtp = @import("rtp.zig");
const mp4 = @import("mp4.zig");

const File = opaque {};
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*File;
extern fn fread(buf: [*]u8, size: usize, count: usize, file: *File) usize;
extern fn fwrite(buf: [*]const u8, size: usize, count: usize, file: *File) usize;
extern fn fclose(file: *File) c_int;
extern fn rewind(file: *File) void;
extern fn remove(path: [*:0]const u8) c_int;
extern fn printf(fmt: [*:0]const u8, ...) c_int;

/// at 30 pictures a second, almost two hours
const max_pictures = 200_000;
/// a picture must fit; the K1's are around 50 kB
const window_bytes = 8 * 1024 * 1024;

var window: [window_bytes]u8 = undefined;
var sample: [window_bytes]u8 = undefined;
var sizes: [max_pictures]u32 = undefined;
var keys: [max_pictures]u32 = undefined;
var head: [8 * max_pictures + 4096]u8 = undefined;
var sps_buf: [256]u8 = undefined;
var pps_buf: [256]u8 = undefined;

/// Hands out the pictures of a stream one by one, reading as it goes.
const Pictures = struct {
    file: *File,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    fn next(p: *Pictures) !?[]const u8 {
        while (true) {
            const have = window[p.start..p.end];
            if (rtp.pictureEnd(have)) |len| {
                p.start += len;
                return have[0..len];
            }
            if (p.eof) {
                // what is left is the last picture, if it is one
                p.start = p.end;
                var nals: rtp.NalIterator = .{ .data = have };
                while (nals.next()) |nal| switch (nal[0] & 0x1f) {
                    1, 5 => return have,
                    else => {},
                };
                return null;
            }
            if (p.start > 0) {
                std.mem.copyForwards(u8, window[0..have.len], have);
                p.end = have.len;
                p.start = 0;
            }
            if (p.end == window.len) return error.PictureTooLarge;
            const n = fread(window[p.end..].ptr, 1, @min(window.len - p.end, 256 * 1024), p.file);
            if (n == 0) p.eof = true;
            p.end += n;
        }
    }
};

fn convert(rate: u32, in_path: [*:0]const u8, out_path: [*:0]const u8) !u32 {
    const in = fopen(in_path, "rb") orelse return error.CannotOpenInput;
    defer _ = fclose(in);

    var count: u32 = 0;
    var key_count: u32 = 0;
    var sps: ?[]const u8 = null;
    var pps: ?[]const u8 = null;
    var pictures: Pictures = .{ .file = in };
    while (try pictures.next()) |picture| {
        const size = mp4.sampleSize(picture);
        if (size == 0) continue;
        if (count == max_pictures) return error.TooManyPictures;
        if (rtp.isKeyPicture(picture)) {
            keys[key_count] = count + 1;
            key_count += 1;
        }
        if (sps == null or pps == null) {
            var nals: rtp.NalIterator = .{ .data = picture };
            while (nals.next()) |nal| {
                if (nal.len > sps_buf.len) continue;
                if (nal[0] & 0x1f == 7 and sps == null) {
                    @memcpy(sps_buf[0..nal.len], nal);
                    sps = sps_buf[0..nal.len];
                } else if (nal[0] & 0x1f == 8 and pps == null) {
                    @memcpy(pps_buf[0..nal.len], nal);
                    pps = pps_buf[0..nal.len];
                }
            }
        }
        sizes[count] = @intCast(size);
        count += 1;
    }
    if (count == 0) return error.NoPictures;
    const header = mp4.header(.{
        .sps = sps orelse return error.NoParameterSets,
        .pps = pps orelse return error.NoParameterSets,
        .rate = rate,
        .sizes = sizes[0..count],
        .key_samples = keys[0..key_count],
    }, &head) orelse return error.CannotDescribeStream;

    const out = fopen(out_path, "wb") orelse return error.CannotOpenOutput;
    errdefer _ = remove(out_path);
    errdefer _ = fclose(out);
    if (fwrite(header.ptr, 1, header.len, out) != header.len) return error.WriteFailed;
    rewind(in);
    pictures = .{ .file = in };
    var written: u32 = 0;
    while (try pictures.next()) |picture| {
        const size = mp4.sampleSize(picture);
        if (size == 0) continue;
        // the input must not have changed between the two readings
        if (written == count or size != sizes[written]) return error.InputChanged;
        mp4.writeSample(picture, sample[0..size]);
        if (fwrite(&sample, 1, size, out) != size) return error.WriteFailed;
        written += 1;
    }
    if (written != count) return error.InputChanged;
    if (fclose(out) != 0) return error.WriteFailed;
    return count;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len != 4) {
        _ = printf("usage: %s <frames per second> <in.h264> <out.mp4>\n", argv[0]);
        return 2;
    }
    const rate = std.fmt.parseInt(u32, std.mem.span(argv[1]), 10) catch 0;
    if (rate == 0 or rate > 240) {
        _ = printf("h264-to-mp4: the frame rate must be a whole number from 1 to 240\n");
        return 2;
    }
    const count = convert(rate, argv[2], argv[3]) catch |failure| {
        _ = printf("h264-to-mp4: %s\n", @errorName(failure).ptr);
        return 1;
    };
    _ = printf("h264-to-mp4: %u pictures, %u s\n", count, count / rate);
    return 0;
}

test {
    _ = mp4;
}
