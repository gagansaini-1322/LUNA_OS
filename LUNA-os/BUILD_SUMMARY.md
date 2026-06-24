# Luna OS — Build Summary

## What this is

A complete `live-build` project for Luna OS, an ultra-lightweight,
gaming-only Debian Bookworm live distribution. Boots from USB, BIOS or
UEFI, with persistence built in.

## Build targets

| Target | Value |
|---|---|
| ISO size | < 4 GB |
| Idle RAM | < 400 MB |
| Boot time | < 10 s to desktop |
| RAM minimum | 1 GB (2 GB recommended) |

## Directory layout

```
LUNA-os/
├── auto/config                          live-build configuration
├── build.sh                             direct build (with FS sanity checks)
├── docker-build.sh                      containerized build (avoids host FS issues)
├── test-boot.sh                         QEMU boot test (bios/uefi/persistence)
├── BUILD_SUMMARY.md                     this file
└── config/
    ├── package-lists/
    │   ├── luna.list.chroot             base system + minimal XFCE4
    │   ├── gaming.list.chroot           GameMode, MangoHud, RetroArch, Wine, Lutris
    │   └── live.list.chroot             live-boot infrastructure
    ├── hooks/live/
    │   ├── 0010-zram-setup.hook.chroot          ZRAM 50%/lz4, disables disk swap
    │   ├── 0020-disable-services.hook.chroot    strips bluetooth/cups/avahi/etc.
    │   ├── 0030-app-store-perms.hook.chroot     locks down App Store helper perms
    │   ├── 0040-plymouth-theme.hook.chroot       registers Luna Plymouth theme
    │   └── 0050-persistence-setup.hook.chroot   persistence integrity check
    ├── includes.chroot/                  files copied into the live filesystem
    │   ├── etc/gamemode.ini
    │   ├── etc/mangohud/MangoHud.conf
    │   ├── etc/sysctl.d/99-luna-gaming.conf
    │   ├── etc/udev/rules.d/60-luna-io-scheduler.rules
    │   ├── etc/udev/rules.d/70-luna-controllers.rules
    │   ├── etc/systemd/system/luna-mm-tweaks.service
    │   ├── etc/lightdm/lightdm.conf.d/50-luna-autologin.conf
    │   ├── etc/sudoers.d/luna-app-store
    │   ├── etc/skel/.config/xfce4/.../xfce4-desktop.xml
    │   ├── usr/share/luna-app-store/        App Store GTK3 app + catalog
    │   ├── usr/lib/luna-app-store/          install helper + wallpaper switcher
    │   ├── usr/share/plymouth/themes/luna/  boot splash theme
    │   └── usr/share/backgrounds/luna/      7 genre wallpapers
    └── includes.binary/                  files copied onto the ISO itself
        └── boot/grub/                     themed GRUB menu (4 entries)
```

## Component notes

### Performance stack
- **ZRAM**: 50% of RAM, lz4 compression, disk swap disabled entirely.
- **GameMode**: performance governor while gaming, `schedutil` at idle.
  Whitelisted for Lutris, RetroArch, and Wine.
- **Kernel**: `linux-image-lowlatency`, THP defrag off, MGLRU on.
- **I/O scheduler**: mq-deadline (USB), bfq (HDD), none (NVMe) via udev.
- **Services stripped**: bluetooth, cups, avahi, ModemManager, whoopsie,
  apport. Modules blacklisted: btusb, bluetooth, usblp, uvcvideo, lirc_dev.

### Game launcher
Uses **Lutris**, under its real name and branding — no rebranded/disguised
third-party client. Lutris is whitelisted in GameMode for automatic
performance-mode switching.

### App Store
GTK3 Python app (`luna_app_store.py`) listing 8 real, free, open-source
games (0 A.D., SuperTuxKart, Battle for Wesnoth, Warzone 2100, Xonotic,
Teeworlds, Extreme Tux Racer, Dungeon Crawl Stone Soup). Installs go
through a narrow, catalog-validated root helper
(`/usr/lib/luna-app-store/luna-install-game`) — the GUI never has
unrestricted root/apt access. Launching a game also swaps the desktop
wallpaper to match its genre and reverts to default on exit.

### Boot experience
- LightDM autologin, no login screen, straight to XFCE.
- Plymouth theme is **script-driven** (pulsing glow + progress bar) rather
  than a multi-frame image sequence — keeps the whole theme under 200 KB.
- GRUB theme: dark background, neon blue title text, 4 menu entries
  (normal / persistence-disabled / safe graphics / UEFI firmware reboot).

### Persistence
Uses live-boot's native `persistence` boot parameter (set in `grub.cfg`)
plus an overlayfs-backed read-write layer. A custom systemd unit
(`luna-persistence-check.service`) runs `e2fsck` on the persistence
partition early in boot; if it's corrupt, live-boot's normal fallback
behavior (clean session) takes over rather than a failed boot.

### Controllers
udev rules (`70-luna-controllers.rules`) tag Xbox (xpad), PS3/PS4
(Sony vendor ID), and generic HID gamepads with `uaccess` so they work
for the logged-in user with zero manual configuration.

## Building

```bash
# Direct build (run on a native ext4/btrfs/xfs filesystem, NOT NTFS/exFAT)
sudo ./build.sh

# OR: containerized build (works regardless of host filesystem)
./docker-build.sh
```

## Testing

```bash
./test-boot.sh bios          # BIOS boot test
./test-boot.sh uefi          # UEFI boot test (requires `ovmf` package)
./test-boot.sh persistence   # boots with an attached persistence test disk
```

Inside the test VM, verify idle RAM with `free -h` — target is under 400 MB.

## Known constraints / things to verify on real hardware

- `linux-image-lowlatency` and the libretro core packages listed in
  `gaming.list.chroot` should be checked against the current Bookworm
  archive at build time — package names occasionally shift between point
  releases.
- The Plymouth script theme assumes the `script` Plymouth plugin is
  available (`plymouth-themes` package); confirmed in `luna.list.chroot`.
- GRUB's `fwsetup` menu entry only works on real UEFI firmware that
  exposes the `OsIndicationsSupported` capability — it's a no-op (safely
  ignored) on BIOS-only systems or in QEMU without OVMF.
