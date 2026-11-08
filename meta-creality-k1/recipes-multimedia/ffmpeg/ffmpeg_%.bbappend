# ffmpeg only muxes here: the H.264 stream from the Helix codec, or the MJPEG
# frames when the codec fails, into MP4 with -c copy, and it applies the flip
# and rotate filters moonraker-timelapse puts on the preview image. The Twitch
# stream (k1os-twitch) wraps the same kind of H.264 into FLV over RTMP and adds
# a silent AAC track from the lavfi input device (anullsrc), which lives in
# libavdevice. No external codec libraries, no X11; the h264 demuxer and the
# flv muxer need LICENSE_FLAGS_ACCEPTED += "commercial" (kas-creality-k1.yml).
PACKAGECONFIG = "avcodec avformat avfilter avdevice swscale swresample gpl zlib"

# Poky's recipe puts the MIPS configure flags behind the "mips" override, which
# is the big-endian TARGET_ARCH only; a mipsel build gets none of them and
# configure then turns on Loongson-3 inline assembly (dmult, dsrl: 64-bit
# instructions) and MSA, and libavcodec does not assemble for the XBurst2.
# "mipsarch" is the override every MIPS tune sets.
EXTRA_OECONF:append:mipsarch = " --extra-libs=-latomic --disable-mips32r5 --disable-mipsdsp --disable-mipsdspr2 \
                                 --disable-loongson2 --disable-loongson3 --disable-mmi --disable-msa"
