# Pf1007lScenic

Interactive [Scenic](https://github.com/ScenicFramework/scenic) UI firmware application for the Allwinner A33 PF1007L 10.1" (800×1280) touchscreen digital photo frame.

## Features

- **800×1280 Portrait Framebuffer Rendering**: Uses `scenic_driver_local` (`cairo-fb` backend on `/dev/fb0`) paired with `/usr/bin/pf1007l-dsi-init` in `Pf1007lScenic.Application` for rock-solid 60 FPS MIPI-DSI video scanout.
- **Calibrated Multi-Touch Input**: Uses `scenic_driver_local` (`evdev` input backend on `silead_ts`) with a `{{800 / 640, 0.0, 0.0}, {0.0, 1280 / 960, 0.0}}` affine calibration matrix and mailbox `:cursor_pos` coalescing for low-latency touch/drag tracking.
- **USB Gadget Networking & SSH**: Exposes `usb0` (`172.31.101.185`) via `nerves_pack` / `vintage_net_direct` for instant `ssh 172.31.101.185` IEx access and `mix upload 172.31.101.185` OTA updates.

## Quick Start

```bash
export MIX_TARGET=pf1007l
mix deps.get
mix firmware

# First-time microSD flash:
mix burn
# Or write a raw disk image:
mix firmware.image pf1007l_scenic.img

# Subsequent updates over USB Ethernet:
mix upload 172.31.101.185
```

