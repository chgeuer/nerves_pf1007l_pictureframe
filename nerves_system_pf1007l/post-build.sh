#!/bin/sh
set -e

mkdir -p $TARGET_DIR/boot
cp -f $BINARIES_DIR/*.dtb $TARGET_DIR/boot/ || true
cp -f $BINARIES_DIR/zImage $TARGET_DIR/boot/zImage || true
"$HOST_DIR/sbin/depmod" -a -b "$TARGET_DIR" 6.12.34 2>/dev/null || true

if [ -f "$NERVES_DEFCONFIG_DIR/c_src/pf1007l_dsi_init.c" ]; then
    mkdir -p "$TARGET_DIR/usr/bin"
    "$HOST_DIR/bin/armv7-nerves-linux-gnueabihf-gcc" -O2 -Wall \
        -o "$TARGET_DIR/usr/bin/pf1007l-dsi-init" \
        "$NERVES_DEFCONFIG_DIR/c_src/pf1007l_dsi_init.c"
fi

if [ -f "$NERVES_DEFCONFIG_DIR/c_src/pf1007l_accel.c" ]; then
    mkdir -p "$TARGET_DIR/usr/bin"
    "$HOST_DIR/bin/armv7-nerves-linux-gnueabihf-gcc" -O2 -Wall \
        -o "$TARGET_DIR/usr/bin/pf1007l-accel" \
        "$NERVES_DEFCONFIG_DIR/c_src/pf1007l_accel.c"
fi

mkdir -p $TARGET_DIR/usr/share/fwup
$HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR
