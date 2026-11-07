# Ingenic XBurst2 (X2000): the FPU has 64-bit registers and only the 2008 NaN
# encoding ("Options implemented: ... nan_2008"); it has no legacy FR=0 mode.
# Poky's mips32r2el tune builds the o32 legacy FP32 ABI with legacy NaN, which
# this kernel then runs through its FPU emulator: 1.7e9 emulated instructions
# in a few minutes of Klipper, 90 % of its CPU time in the kernel, and the MCU
# shut down with "Missed scheduling". The stock Creality userspace is built
# -mfp64 -mnan=2008 (e_flags 0x70001407, "Hard float (32-bit CPU, 64-bit FPU)").
require conf/machine/include/mips/tune-mips32r2.inc

TUNEVALID[fp64] = "o32 FP64 ABI with 2008 NaN encoding (XBurst2 FPU)"
TUNE_CCARGS .= "${@bb.utils.contains('TUNE_FEATURES', 'fp64', ' -mfp64 -mnan=2008', '', d)}"

AVAILTUNES += "mips32r2el-fp64"
TUNE_FEATURES:tune-mips32r2el-fp64 = "${TUNE_FEATURES:tune-mips32r2el} fp64"
MIPSPKGSFX_VARIANT:tune-mips32r2el-fp64 = "mips32r2el-fp64"
# Only packages built with this tune are binary-compatible.
PACKAGE_EXTRA_ARCHS:tune-mips32r2el-fp64 = "mips32r2el-fp64"
