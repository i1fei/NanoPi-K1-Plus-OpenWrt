# Stage A HDMI Console

## TTL

Serial console remains enabled on `ttyS0`.

Settings:

- 115200 baud
- 8N1

The DTS still uses:

```dts
stdout-path = "serial0:115200n8";
```

## HDMI

HDMI is prepared as a Linux text console on `tty1`.

This stage enables the H5 HDMI connector path in the Linux DTS and keeps the serial console in the kernel command line.

Expected kernel command line console entries:

```text
console=ttyS0,115200
console=tty1
```

## USB

Ordinary USB host keyboards are prepared through USB HID support.

This is not USB gadget HID.

## Local Login

The sunxi image already provides login prompts for both:

- `ttyS0`
- `tty1`

## Not Included

This stage does not include:

- desktop environment
- browser
- X11
- Wayland
- graphical LuCI
- Wi-Fi changes
- Bluetooth
- audio
- Docker
- proxy plugins
