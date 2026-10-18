# Nerves + Scenic on the Allwinner A33 PF1007L Digital Photo Frame

Custom [Elixir Nerves](https://nerves-project.org/) system (`nerves_system_pf1007l`) and [Scenic](https://github.com/ScenicFramework/scenic) touchscreen UI application (`pf1007l_scenic`) for the **PF1007L** (`AEEZO` / `yhk_zr789_sq9365_101`) 10.1" 800×1280 IPS touchscreen digital photo frame powered by the **Allwinner A33 (`sun8i-a33`)** SoC, Like [this one from amazon.de](https://www.amazon.de/dp/B0GDFBNPHX).

Nerves boots entirely from an external **microSD card (`mmc0` / `/dev/mmcblk0`)**, leaving the factory Android installation on the internal 16 GB eMMC (`mmc2` / `/dev/mmcblk1`) untouched. Removing the microSD card boots the original stock firmware.

<video src="https://raw.githubusercontent.com/chgeuer/nerves_pf1007l_pictureframe/refs/heads/main/docs/demo.mp4"></video>

---

## Repository Structure

| Directory | Description |
| --- | --- |
| [`nerves_system_pf1007l/`](./nerves_system_pf1007l) | Custom Nerves System (Buildroot + mainline **Linux 6.12.34** + **U-Boot 2025.10**) with PF1007L device tree, JD9365DA 800×1280 MIPI-DSI panel support, Silead GSL1680 touchscreen driver + built-in firmware, RTL8723DS Wi-Fi driver, Cairo/Pango/Fontconfig for Scenic, and USB CDC Ethernet gadget. |
| [`pf1007l_scenic/`](./pf1007l_scenic) | Nerves + Scenic firmware application rendering a 60 FPS interactive UI to `/dev/fb0` via `scenic_driver_local` with calibrated `silead_ts` capacitive touch input, VintageNet USB gadget networking (`172.31.101.185`), and SSH / OTA firmware updates (`mix upload`). |
| [`justfile`](./justfile) | Task runner codifying firmware builds (`just firmware`), microSD card flashing (`just burn`), OTA updates (`just upload`), remote IEx/logs (`just ssh`, `just logs`, `just dmesg`), and kernel/system rebuilds (`just kernel-rebuild`, `just kernel-save-patch`). |

---

## Quick Usage with `just`

```bash
just --list           # List all recipes
just status           # Check USB devices, microSD reader, and 172.31.101.185 connectivity
just firmware         # Build pf1007l_scenic.fw
just image            # Build both .fw and raw bootable pf1007l_scenic.img
just burn             # Auto-detect the microSD card in your reader and burn the complete image
just upload           # Build and push an OTA A/B firmware update to 172.31.101.185
just ssh              # Open an interactive IEx shell on the picture frame
just logs             # Dump recent RingLogger output over SSH
just dmesg            # Dump kernel dmesg over SSH
just dsi-init         # Cross-compile c_src/pf1007l_dsi_init.c -> rootfs_overlay/usr/bin/pf1007l-dsi-init
just kernel-rebuild   # Rebuild Linux 6.12.34 + DTB and repackage the Nerves system artifact
```

---

## Hardware Architecture & Reverse-Engineered Pinout

The PF1007L (`yhk_zr789_sq9365_101`) uses an Allwinner A33 (`sun8i-a33`) with **discrete fixed voltage regulators** (no AXP223 PMIC on `r_rsb`):

| Subsystem | Hardware / IC | A33 Bus / Pins | Linux Driver / Notes |
| --- | --- | --- | --- |
| **SoC / CPU** | Allwinner A33 (4× Cortex-A7) | `PLL_CPUX` @ 408 MHz | Fixed `VDD-CPU` rail (no PMIC); OPPs above 408 MHz are removed in DT to prevent brownout when `cpufreq-dt` probes |
| **RAM** | 1 GiB DDR3 | `PLL_DDR` @ 432 MHz | Configured in U-Boot SPL (`CONFIG_DRAM_CLK=432`, `CONFIG_DRAM_ZQ=15291`) |
| **MIPI-DSI Panel** | Jadard JD9365DA (`sq9365_101`), 800×1280, 4-lane | `MIPI-DSI` + `D-PHY` + `TCON0`, Reset: `PH7` | `panel-jadard-jd9365da-h3` + `/usr/bin/pf1007l-dsi-init` (non-burst sync-pulse video mode, 66 MHz dotclock, `hfp=20, hbp=20, hsync=20`, `vfp=30, vbp=12, vsync=4`) |
| **Backlight** | PWM LED Backlight | PWM0: `PH0`, Enable: `PH6` | `pwm-backlight` + `pf1007l-dsi-init` (20 kHz PWM on `PH0`, active-high enable on `PH6`) |
| **Touchscreen** | Silead GSL1680 (`gsl_m86_hd`) | `I2C0` (`PB0` SCK, `PB1` SDA) @ `0x40`, Wake/Shutdown: `PH1`, IRQ: `PB5` | Patched `silead` driver (`drivers/input/touchscreen/silead.c`) with built-in `silead/gsl1680.fw` (10×15 sensor grid → raw `640×960` with `touchscreen-swapped-x-y`, scaled `1.25×` / `1.333×` to `800×1280`) |
| **Wi-Fi** | Realtek RTL8723DS SDIO | `MMC1` (`PG0`–`PG5`), Power: `PL2` (`3.3V`) | Out-of-tree `rtl8723ds` or SDIO driver on `mmc1` |
| **USB OTG** | MUSB Dual-Role Controller | USB0 (`USB-DM0` / `USB-DP0`) | Forced `dr_mode = "peripheral"` with `g_cdc` (`usb0` CDC ECM Ethernet + `ttyGS0` serial) |
| **Storage** | External microSD (`mmc0`), Internal 16 GB eMMC (`mmc2`) | `MMC0` (`PF0`–`PF5`, CD `PB4`), `MMC2` (`PC5`–`PC16`) | Boots Nerves from `/dev/mmcblk0` (A/B SquashFS rootfs + F2FS `/root`) |

---

## Key Hardware Fixes Included

1. **CPU Frequency Stability (`sun8i-a33-pf1007l.dts`)**:
   Because this board omits the AXP223 PMIC (`VDD-CPU` is fixed at ~1.1 V), allowing `cpufreq-dt` to switch `CLK_CPUX` above 408 MHz causes immediate instruction corruption. All OPPs above 408 MHz (`480 MHz`–`1008 MHz`) are deleted from `&cpu0_opp_table`.
2. **Jadard JD9365DA MIPI-DSI 60 FPS Video Scanout (`panel-jadard-jd9365da-h3.c`, `sun6i_mipi_dsi.c`, `pf1007l_dsi_init.c`)**:
   - Enters `DSI_START_LP11` before panel reset/prepare so the panel exits sleep cleanly (`0x0A = 0x9C`).
   - Sets Page 3 register `0xE6 = 0x00` (instead of `0x02`) in the 203-command vendor table so the JD9365DA internal watchdog does not clear `DISON` (`0x0A` bit 2) in non-burst mode.
   - Uses **non-burst video mode (`MIPI_DSI_MODE_VIDEO_SYNC_PULSE`)** (`DSI_CMD_CTL = 0x00`, `DSI_INST_FUNC[0] = 0x1F` all 4 lanes + clock in HS, `DSI_BASIC_SIZE1 = 0x002E0500`, `TCON_DRQ = 0`).
   - Unbinds `vtcon1` (`fbcon`) and sets `console=ttyS0,115200` so the Linux text console never overwrites Scenic's `/dev/fb0` framebuffer.
3. **Silead GSL1680 Capacitive Touchscreen (`drivers/input/touchscreen/silead.c`)**:
   - The GSL1680 requires a **4-byte block write** of `{0x00, 0x00, 0x00, 0x00}` to `SILEAD_REG_POWER` (`0xBC`) during reset; mainline's 1-byte `i2c_smbus_write_byte_data(client, 0xBC, 0x00)` left bits 8..31 of `0xBC` uninitialized and prevented the DSP from starting (`0xB0 != 0x5A5A5A5A`).
   - Added the stock `init_chip` sequence (`0x80 = 0x03`, double `reset -> startup`, and 30 ms settle delay) and embedded `silead/gsl1680.fw` directly into the kernel (`CONFIG_EXTRA_FIRMWARE="silead/gsl1680.fw"`).
   - Configured the 2D affine calibration matrix `{{800 / 640, 0.0, 0.0}, {0.0, 1280 / 960, 0.0}}` in `pf1007l_scenic/config/target.exs` to map the GSL1680's `640×960` coordinate space (10×15 tiles × 64 units) 1:1 across the `800×1280` display.

---

## Building & Deploying from Scratch

### Prerequisites

- Linux host (`x86_64`) with standard Buildroot dependencies (`build-essential`, `libncurses-dev`, `bc`, `unzip`, `rsync`, `cpio`, `squashfs-tools`, `fwup`, `libmnl-dev`, `libnl-genl-3-dev`)
- Elixir `~> 1.17` / `~> 1.20` and Erlang/OTP `27`–`29`
- `nerves_bootstrap` archive installed:
  ```bash
  mix local.hex --force
  mix local.rebar --force
  mix archive.install hex nerves_bootstrap --force
  ```

### Step 1: Build the Firmware

From the `pf1007l_scenic/` directory:

```bash
cd pf1007l_scenic
export MIX_TARGET=pf1007l
mix deps.get
mix firmware
```

> **Note:** On the very first build (when no prebuilt artifact exists in `nerves_system_pf1007l/.nerves/artifacts/`), `nerves_system_pf1007l` is configured with `nerves: [compile: true]` in `pf1007l_scenic/mix.exs` and will automatically run Buildroot to compile U-Boot, Linux 6.12.34, and the root filesystem (~30–45 minutes). Subsequent `mix firmware` builds take only a few seconds.

### Step 2: Flash a MicroSD Card (First-Time Provisioning)

Insert a microSD card into your computer and burn the image directly:

```bash
cd pf1007l_scenic
MIX_TARGET=pf1007l mix burn
```

Or generate a standalone raw `.img` file that can be written with `dd` or `fwup`:

```bash
cd pf1007l_scenic
MIX_TARGET=pf1007l mix firmware.image pf1007l_scenic.img
sudo dd if=pf1007l_scenic.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Insert the microSD card into the PF1007L slot and connect the USB cable. Within ~12 seconds:
1. The screen illuminates and displays the **Nerves + Scenic on PF1007L** interactive UI.
2. A USB CDC Ethernet gadget interface (`usb0`) enumerates on your host computer and self-assigns `172.31.101.185` (via VintageNet `usb0` DHCP/link-local).

### Step 3: Over-the-Air (OTA) Firmware Updates & Remote IEx Shell

Once booted from microSD with the USB cable attached, you never need to remove the microSD card again:

- **Connect to the live IEx shell over SSH**:
  ```bash
  ssh 172.31.101.185
  ```
- **Push firmware updates over USB (`fwup` A/B partition upgrade)**:
  ```bash
  cd pf1007l_scenic
  MIX_TARGET=pf1007l mix firmware
  MIX_TARGET=pf1007l mix upload 172.31.101.185
  ```
