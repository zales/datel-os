# XBurst2: default the compiler to the o32 FP64 ABI and 2008 NaN, matching the
# -mfp64 -mnan=2008 in TUNE_CCARGS (see conf/machine/include/tune-mips32r2el-fp64.inc).
EXTRA_OECONF:append:mipsel = " --with-arch=mips32r2 --with-fp-32=64 --with-nan=2008"
