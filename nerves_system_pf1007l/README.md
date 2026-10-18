# NervesSystemPf1007l

Custom Nerves system for the Allwinner A33 (`sun8i-a33`) PF1007L 10.1" 800x1280 IPS Touchscreen Digital Photo Frame (`AEEZO` / `yhk_zr789_sq9365_101`).

## Hardware supported

- **SoC**: Allwinner A33 (4x Cortex-A7, VFPv4/NEON, 1 GiB DDR3, fixed discrete regulators / no PMIC)
- **Display**: 10.1" 800x1280 MIPI-DSI 4-lane panel (`jadard,sq9365-101` via mainline `sun4i-drm` + `sun6i-mipi-dsi`, `/dev/dri/card0` and `/dev/fb0`)
- **Backlight**: PWM0 (`PH0`) + backlight enable (`PH6`) via `pwm-backlight`
- **Touchscreen**: Silead GSL1680 (`gsl_m86_hd` on `i2c0` @ `0x40`, IRQ `PB5`, power `PH1`) via mainline `silead` driver (`/dev/input/event*`)
- **USB OTG Gadget**: `g_cdc` composite gadget on `musb-hdrc` providing USB Ethernet (`usb0`) and USB serial (`ttyGS0`)
- **Storage**: Boot from microSD (`mmc0` / `/dev/mmcblk0`), with internal 16 GB eMMC (`mmc2` / `/dev/mmcblk1`) preserved
