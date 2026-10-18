set shell := ["bash", "-euo", "pipefail", "-c"]

root_dir := justfile_directory()
system_dir := root_dir / "nerves_system_pf1007l"
app_dir := root_dir / "pf1007l_scenic"
artifact_dir := system_dir / ".nerves/artifacts/nerves_system_pf1007l-portable-0.1.0"
fw_file := app_dir / "_build/pf1007l_dev/nerves/images/pf1007l_scenic.fw"
img_file := app_dir / "pf1007l_scenic.img"
default_ip := "172.31.101.185"

# Prepend OTP 29 / Elixir 1.20.4 if installed via .elixir-install on the host
export PATH := "/home/chgeuer/.elixir-install/installs/elixir/1.20.4-otp-29/bin:/home/chgeuer/.elixir-install/installs/otp/29.1/bin:" + env_var("PATH")
export MIX_TARGET := "pf1007l"

# List available recipes
default:
    @just --list

# Check USB, microSD reader, and USB Ethernet status of the picture frame
status ip=default_ip:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== USB Devices (Allwinner FEL 1f3a:efe8 / Nerves Gadget 0525:a4a2 / Card Reader) ==="
    lsusb | grep -iE "1f3a|0525|8564|Reader|Gadget|Allwinner" || echo "  (none matched)"
    echo ""
    echo "=== Removable Block Devices (microSD Reader) ==="
    lsblk -o NAME,SIZE,TYPE,RM,MOUNTPOINT,MODEL | grep -E "NAME| 1 " || true
    echo ""
    echo "=== USB Network Interface & Ping ({{ip}}) ==="
    ip -br addr | grep -E "usb|eth0|172\.31\.101" || echo "  (USB network interface down)"
    if ping -c 1 -W 1 "{{ip}}" >/dev/null 2>&1; then
        echo "  Reachable at {{ip}} ✅"
    else
        echo "  Not reachable at {{ip}} ❌"
    fi

# Fetch Mix dependencies for the Scenic Nerves app
deps:
    cd "{{app_dir}}" && mix deps.get

# Cross-compile the MIPI-DSI + D-PHY + TCON0 + JD9365DA hardware initializer binary
dsi-init:
    #!/usr/bin/env bash
    set -euo pipefail
    GCC="{{artifact_dir}}/host/bin/armv7-nerves-linux-gnueabihf-gcc"
    if [ ! -x "$GCC" ]; then
        GCC="$(command -v armv7-nerves-linux-gnueabihf-gcc || command -v arm-linux-gnueabihf-gcc)"
    fi
    mkdir -p "{{system_dir}}/rootfs_overlay/usr/bin" "{{app_dir}}/rootfs_overlay/usr/bin"
    "$GCC" -O2 -Wall -o "{{system_dir}}/rootfs_overlay/usr/bin/pf1007l-dsi-init" "{{system_dir}}/c_src/pf1007l_dsi_init.c"
    cp -f "{{system_dir}}/c_src/pf1007l_dsi_init.c" "{{app_dir}}/c_src/pf1007l_dsi_init.c"
    cp -f "{{system_dir}}/rootfs_overlay/usr/bin/pf1007l-dsi-init" "{{app_dir}}/rootfs_overlay/usr/bin/pf1007l-dsi-init"
    ls -lh "{{app_dir}}/rootfs_overlay/usr/bin/pf1007l-dsi-init"

# Build the Nerves firmware bundle (.fw)
firmware:
    cd "{{app_dir}}" && mix firmware
    @ls -lh "{{fw_file}}"

# Build both the .fw bundle and a raw bootable microSD image (pf1007l_scenic.img)
image: firmware
    rm -f "{{img_file}}"
    cd "{{app_dir}}" && mix firmware.image "{{img_file}}"
    @ls -lh "{{img_file}}"

# Burn the firmware image to a microSD card (auto-detects card reader if device is omitted)
burn device="": firmware
    #!/usr/bin/env bash
    set -euo pipefail
    DEV="{{device}}"
    if [ -z "$DEV" ]; then
        DEV="$(lsblk -dpno NAME,RM,SIZE | awk '$2 == "1" && $3 != "0B" {print $1; exit}')"
    fi
    if [ -z "$DEV" ]; then
        echo "ERROR: No microSD card with non-zero size detected in reader."
        echo "Insert the microSD card into your computer's card reader and run: just burn"
        exit 1
    fi
    FWUP_BIN="$(command -v fwup || echo "{{artifact_dir}}/host/bin/fwup")"
    echo "Unmounting any auto-mounted partitions on $DEV..."
    for mp in $(lsblk -lnpo NAME,MOUNTPOINT "$DEV" | awk '$2 != "" {print $1}'); do
        udisksctl unmount -b "$mp" 2>/dev/null || sudo -n umount "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || true
    done
    echo "Burning {{fw_file}} (task: complete) to $DEV using $FWUP_BIN..."
    lsblk "$DEV"
    if [ -w "$DEV" ]; then
        "$FWUP_BIN" -a -y -i "{{fw_file}}" -d "$DEV" -t complete
    else
        sudo "$FWUP_BIN" -a -y -i "{{fw_file}}" -d "$DEV" -t complete
    fi
    sync
    sleep 1
    for mp in $(lsblk -lnpo NAME,MOUNTPOINT "$DEV" | awk '$2 != "" {print $1}'); do
        udisksctl unmount -b "$mp" 2>/dev/null || sudo -n umount "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || true
    done
    echo "Done! Safely remove the microSD card, insert it into the PF1007L, and plug in USB."

# Build and upload firmware over USB Ethernet (OTA A/B upgrade via SSH fwup)
upload ip=default_ip: firmware
    ssh-keygen -R "{{ip}}" 2>/dev/null || true
    ssh-keyscan -H "{{ip}}" >> ~/.ssh/known_hosts 2>/dev/null || true
    cd "{{app_dir}}" && mix upload "{{ip}}"

# Open an interactive IEx shell on the picture frame over SSH
ssh ip=default_ip:
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "{{ip}}"

# Run a single Elixir expression on the picture frame over SSH
cmd expr ip=default_ip:
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "{{ip}}" "{{expr}}"

# Print recent RingLogger messages from the picture frame
logs count="100" ip=default_ip:
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "{{ip}}" "RingLogger.tail({{count}})"

# Print kernel dmesg from the picture frame
dmesg ip=default_ip:
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "{{ip}}" ':os.cmd(~c"dmesg | tail -n 80") |> IO.puts()'

# Reboot the picture frame remotely
reboot ip=default_ip:
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "{{ip}}" "Nerves.Runtime.reboot()"

# Update the Nerves artifact CHECKSUM file to match current nerves_system_pf1007l sources
system-checksum:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{artifact_dir}}" ]; then
        echo "No local artifact directory at {{artifact_dir}}"
        exit 0
    fi
    elixir -e '
      dir = "{{system_dir}}"
      paths = ["c_src", "Config.in", "fwup_include", "linux", "rootfs_overlay", "uboot", "fwup-ops.conf", "fwup.conf", "mix.exs", "nerves_defconfig", "post-build.sh", "post-createfs.sh", "README.md", "VERSION"]
      dir_files = fn p -> if File.dir?(p), do: Path.wildcard(Path.join(p, "**")), else: [p] end
      blob =
        paths
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(&Path.wildcard/1)
        |> Enum.flat_map(dir_files)
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&File.regular?/1)
        |> Enum.uniq()
        |> Enum.map(&File.read!/1)
        |> Enum.map(&:crypto.hash(:sha256, &1))
      cs = :crypto.hash(:sha256, blob) |> Base.encode16()
      File.write!(Path.join("{{artifact_dir}}", "CHECKSUM"), cs)
      IO.puts("Updated CHECKSUM: #{cs}")
    '

# Rebuild Linux kernel + DTB and repackage the Nerves system artifact
kernel-rebuild: dsi-init
    #!/usr/bin/env bash
    set -euo pipefail
    cp -f "{{system_dir}}/fwup.conf" "{{artifact_dir}}/images/fwup.conf"
    cp -f "{{system_dir}}/fwup_include/fwup-common.conf" "{{artifact_dir}}/images/fwup_include/fwup-common.conf"
    "{{artifact_dir}}/host/bin/mkenvimage" -s 16384 -o "{{artifact_dir}}/images/uboot-env.bin" "{{system_dir}}/uboot/uboot.env"
    make -C "{{artifact_dir}}" linux-rebuild
    cp -f "{{artifact_dir}}/images/zImage" "{{artifact_dir}}/target/boot/zImage"
    cp -f "{{artifact_dir}}/images/sun8i-a33-pf1007l.dtb" "{{artifact_dir}}/target/boot/sun8i-a33-pf1007l.dtb"
    "{{artifact_dir}}/host/sbin/depmod" -a -b "{{artifact_dir}}/target" 6.12.34
    make -C "{{artifact_dir}}" BR2_EXTERNAL_NERVES_PATH="{{app_dir}}/deps/nerves_system_br" NERVES_DEFCONFIG_DIR="{{system_dir}}" rootfs-squashfs
    just system-checksum

# Regenerate linux/0001-pf1007l-dts-and-panel.patch from build/linux-custom and verify clean apply
kernel-save-patch:
    #!/usr/bin/env bash
    set -euo pipefail
    LINUX_CUSTOM="{{artifact_dir}}/build/linux-custom"
    TARBALL="$HOME/.nerves/dl/linux/linux-6.12.34.tar.xz"
    PATCH_OUT="{{system_dir}}/linux/0001-pf1007l-dts-and-panel.patch"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    FILES=(
        "arch/arm/boot/dts/allwinner/Makefile"
        "arch/arm/boot/dts/allwinner/sun8i-a33-pf1007l.dts"
        "drivers/gpu/drm/panel/panel-jadard-jd9365da-h3.c"
        "drivers/gpu/drm/sun4i/sun6i_mipi_dsi.c"
        "drivers/input/touchscreen/silead.c"
    )
    mkdir -p "$TMP_DIR/a" "$TMP_DIR/b"
    tar -xJf "$TARBALL" -C "$TMP_DIR/a" --strip-components=1 \
        linux-6.12.34/arch/arm/boot/dts/allwinner/Makefile \
        linux-6.12.34/drivers/gpu/drm/panel/panel-jadard-jd9365da-h3.c \
        linux-6.12.34/drivers/gpu/drm/sun4i/sun6i_mipi_dsi.c \
        linux-6.12.34/drivers/input/touchscreen/silead.c
    cp -a "$TMP_DIR/a/." "$TMP_DIR/b/"
    for f in "${FILES[@]}"; do
        mkdir -p "$TMP_DIR/b/$(dirname "$f")"
        cp -f "$LINUX_CUSTOM/$f" "$TMP_DIR/b/$f"
    done
    (cd "$TMP_DIR" && diff -uNr a b > "$PATCH_OUT" || true)
    patch -d "$TMP_DIR/a" -p1 --dry-run < "$PATCH_OUT"
    echo "Updated $PATCH_OUT ($(wc -l < "$PATCH_OUT") lines)"

# Cross-compile the AIC8800DC SDIO Wi-Fi kernel modules against build/linux-custom
wifi-driver:
    #!/usr/bin/env bash
    set -euo pipefail
    KDIR="{{artifact_dir}}/build/linux-custom"
    CROSS="{{artifact_dir}}/host/bin/armv7-nerves-linux-gnueabihf-"
    DRV="{{system_dir}}/c_src/aic8800"
    make -C "$KDIR" M="$DRV" ARCH=arm CROSS_COMPILE="$CROSS" \
        CONFIG_AIC_FW_PATH="/lib/firmware/aic8800_fw/SDIO/aic8800DC" \
        CONFIG_AIC8800_WLAN_SUPPORT=m \
        CONFIG_AIC_INTF_SDIO=y \
        modules -j$(nproc)
    mkdir -p "{{system_dir}}/rootfs_overlay/lib/modules/6.12.34/extra"
    cp -f "$DRV/aic8800_bsp/aic8800_bsp.ko" "$DRV/aic8800_fdrv/aic8800_fdrv.ko" \
        "{{system_dir}}/rootfs_overlay/lib/modules/6.12.34/extra/"
    find "$DRV" \( -name '*.o' -o -name '*.ko' -o -name '*.mod*' -o -name '.*.cmd' -o -name 'modules.order' -o -name 'Module.symvers' \) -delete
    just system-checksum

# Copy local ~/.config/untis/credentials.json to /root/untis_credentials.json on the frame
untis-push-creds ip=default_ip creds="~/.config/untis/credentials.json":
    #!/usr/bin/env bash
    set -euo pipefail
    CREDS_PATH=$(eval echo "{{creds}}")
    B64=$(base64 -w0 "$CREDS_PATH")
    UTC_SEC=$(date -u +%s)
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "{{ip}}" \
        "System.cmd(\"date\", [\"-u\", \"-s\", \"@$UTC_SEC\"]); File.write!(\"/root/untis_credentials.json\", Base.decode64!(\"$B64\")); Task.start(fn -> Pf1007lScenic.Schedule.resume() end)"

# Sync the frame's UTC system clock from the host over SSH
sync-time ip=default_ip:
    #!/usr/bin/env bash
    set -euo pipefail
    UTC_SEC=$(date -u +%s)
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "{{ip}}" \
        "System.cmd(\"date\", [\"-u\", \"-s\", \"@$UTC_SEC\"]); DateTime.utc_now()"
