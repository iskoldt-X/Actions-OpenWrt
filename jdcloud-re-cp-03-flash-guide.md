# ImmortalWrt RE-CP-03 (AX6000) — Custom Build Flash Guide for macOS

A step-by-step guide for flashing the custom ImmortalWrt build produced by this repository onto the JDCloud RE-CP-03 router (MediaTek MT7986A, 128 GB eMMC), from a macOS computer.

| | |
|---|---|
| Router recovery IP | `192.168.1.1` |
| Mac static IP (this guide) | `192.168.1.254` |
| TFTP root on macOS | `/private/tftpboot/` |

---

## ‼️ READ THIS FIRST — Three Things You Must Know

These three points are the difference between a smooth flash and a brick / bootloop. They are not optional.

### 1. This repo's firmware uses a CUSTOM partition layout

This build sets:

```text
CONFIG_TARGET_ROOTFS_PARTSIZE=2048   # 2 GB rootfs (vs. ~100 MB on stock)
```

Therefore **the `gpt.bin` from this repo encodes a different partition table than the official ImmortalWrt release.** Implications:

- You **must** flash GPT / preloader / FIP using the files produced by this repo's build — not the ones from `downloads.immortalwrt.org`.
- The `dd` offsets in this guide match this repo. Do not cross-reference recipes from the upstream wiki — they assume the stock layout.
- If you ever want to revert to a stock build, flash the **stock** `gpt.bin` first, otherwise the rootfs partition will not match what stock images expect.

### 2. For TFTP recovery, use the OFFICIAL small initramfs — never this repo's custom one

This repo's build packs SSR+, Docker, OpenClash, Passwall, etc., so the resulting `initramfs-recovery.itb` is around **85–99 MB**. U-Boot on this device cannot boot a recovery image that large — TFTP appears to transfer it successfully, then the router silently falls back and re-requests the same file in a loop.

**Always use the official, small (~13 MB) initramfs for TFTP recovery.** It is just a temporary RAM environment for running `sysupgrade`, so it does not need any custom packages.

Official file (24.10.6, ~13 MB):

<https://downloads.immortalwrt.org/releases/24.10.6/targets/mediatek/filogic/immortalwrt-24.10.6-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb>

### 3. After sysupgrade succeeds, clear `pstore` — otherwise it boots back into initramfs

On this device, U-Boot inspects `pstore` and **forces a recovery boot** if it finds prior crash / recovery records, even when the new system was flashed correctly. Symptom: `sysupgrade` runs cleanly, the router reboots, you land in initramfs again with `tmpfs on /`.

Fix (run inside the recovery / initramfs shell, **before** `sysupgrade`, and again afterwards if needed):

```sh
rm -f /sys/fs/pstore/*
sync
```

If you are already stuck in initramfs after a flash, run the same `rm`, then `reboot`.

---

## What You Need

### A. The custom firmware (from this repo's GitHub Actions build)

Download the latest successful build from:

<https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-immortalwrt-SSR-AX6000.yml>

1. Sign in to GitHub.
2. Click the most recent green ✅ workflow run.
3. Scroll to the bottom of the run page → **Artifacts** → download the firmware artifact ZIP.
4. Unzip it somewhere convenient, e.g. `~/Downloads/openwrt-custom/`.

You should end up with at least these four files:

```text
immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin
immortalwrt-mediatek-filogic-jdcloud_re-cp-03-preloader.bin
immortalwrt-mediatek-filogic-jdcloud_re-cp-03-bl31-uboot.fip
immortalwrt-mediatek-filogic-jdcloud_re-cp-03-squashfs-sysupgrade.itb
```

There is also a custom `initramfs-recovery.itb` in the artifact — **do not use it for TFTP**. It is only useful for offline analysis.

### B. The official recovery initramfs (small, bootable)

Download from:

<https://downloads.immortalwrt.org/releases/24.10.6/targets/mediatek/filogic/immortalwrt-24.10.6-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb>

Save it to `~/Downloads/`. The file should be roughly **13 MB**. If you got something around 85–99 MB, you grabbed the wrong one.

### C. Hardware

- An ethernet cable from the Mac to the router's LAN port.
- A way to power-cycle the router and reach the reset button.

---

## File Roles — Which File Comes From Where

| File | Source | Used in |
|---|---|---|
| `...-gpt.bin` | **This repo's build (A)** | Phase 3 — write custom GPT |
| `...-preloader.bin` | **This repo's build (A)** | Phase 3 — write BL2 |
| `...-bl31-uboot.fip` | **This repo's build (A)** | Phase 3 — write FIP |
| `...-squashfs-sysupgrade.itb` | **This repo's build (A)** | Phase 5 — final firmware |
| `...-initramfs-recovery.itb` (~13 MB) | **Official ImmortalWrt (B)** | Phase 4 — TFTP recovery only |

---

## Phase 0 — Preflight (on the router)

### 0.1 Verify you are in the real production system

SSH into the router and run:

```sh
df -h
mount
cat /proc/partitions
```

A real production system shows:

```text
/dev/root on /rom type squashfs
/dev/fitrw on /overlay type f2fs
overlayfs:/overlay on / type overlay
```

If `/` is `tmpfs`, you are in initramfs — Phase 3 (writing the bootloader) must be done from the real system, so reboot back into the production system first.

### 0.2 Back up config and bootloader

Backup is cheap; recovery without one can require TTL serial. Do all of these.

On the router:

```sh
# Config
sysupgrade -b /tmp/backup-config.tar.gz

# Bootloader components — in case the new ones brick the device
dd if=/dev/mmcblk0      of=/tmp/backup-gpt.bin       bs=512 count=34
dd if=/dev/mmcblk0boot0 of=/tmp/backup-preloader.bin bs=512 count=2048
dd if=/dev/mmcblk0      of=/tmp/backup-fip.bin       bs=512 skip=13312 count=8192
```

On the Mac, copy those backups off the router:

```sh
scp -O root@192.168.1.1:/tmp/backup-config.tar.gz   ~/Downloads/
scp -O root@192.168.1.1:/tmp/backup-gpt.bin         ~/Downloads/
scp -O root@192.168.1.1:/tmp/backup-preloader.bin   ~/Downloads/
scp -O root@192.168.1.1:/tmp/backup-fip.bin         ~/Downloads/
```

### 0.3 Stop heavy writers before flashing

```sh
/etc/init.d/dockerd  stop 2>/dev/null
/etc/init.d/openclash stop 2>/dev/null
/etc/init.d/passwall stop 2>/dev/null
sync
```

### 0.4 Verify build offsets before flashing

Before writing anything irreversible, sanity-check that the `dd` offsets used in Phase 3 actually match (a) what this build's `gpt.bin` encodes and (b) what is currently on the device. The three offsets come from three different sources, so they need three independent checks:

| Phase 3 step | Offset | Source of truth |
|---|---|---|
| 3.1 GPT | `seek=0 count=34` | GPT spec (always 34 sectors for the primary header + table) |
| 3.2 BL2 | write to `/dev/mmcblk0boot0` | MT7986 BootROM convention |
| 3.3 FIP | `seek=13312` | OpenWrt build script + U-Boot defconfig — **not** stored in `gpt.bin` |

Note: `gpt.bin` only verifies the GPT layout. The FIP offset must be checked separately against the live disk.

#### Check 1 — Parse `gpt.bin` itself (what the new build will install)

Copy `gpt.bin` to the router now (Phase 2 will copy the rest later):

```sh
# from Mac
scp -O ~/Downloads/openwrt-custom/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin \
       root@192.168.1.1:/tmp/
```

On the router, parse it as a disk image (use whichever tool is installed):

```sh
parted /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin unit s print
# or
sgdisk -p /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin
# or, in a pinch
fdisk -l /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin
```

You should see a partition list that includes a rootfs / fitrw partition of about **4 194 304 sectors (~2 GB)** — the result of `CONFIG_TARGET_ROOTFS_PARTSIZE=2048`. If that partition is still ~100 MB, this is **not** the custom build and Phase 3 will not give you what you expect.

#### Check 2 — Compare against the live GPT on the device

```sh
parted /dev/mmcblk0 unit s print
# or
sgdisk -p /dev/mmcblk0
```

Diff the partition starting LBAs against Check 1. Rules of thumb:

- The rootfs / fitrw partition **start LBA** should be the same in both. Its **end LBA** (and therefore size) is the only intentional change.
- All other partitions (`bl2`, `fip`, `factory`, `kernel`, etc., depending on the layout) should start at the **same LBA** in both outputs.
- If non-rootfs partition starts differ, **stop** — the new GPT would shift FIP/env/factory regions and the BL2 won't find them.

#### Check 3 — Confirm FIP really lives at sector 13312 on this device

The FIP offset is not in `gpt.bin`; it's hardcoded in U-Boot. Verify by reading the FIP TOC magic at the expected sector on the live disk:

```sh
dd if=/dev/mmcblk0 bs=512 skip=13312 count=1 2>/dev/null | hexdump -C | head -1
```

Expected output (the four leading bytes are the little-endian encoding of `0xAA640001`, the FIP TOC header magic):

```text
00000000  01 00 64 aa ...
```

If you see those four bytes, sector 13312 is the real FIP start, and `seek=13312` in Phase 3.3 is correct for this device.

If you do **not** see them, scan the first 16 MB to find the actual FIP sector before continuing:

```sh
dd if=/dev/mmcblk0 bs=1M count=16 2>/dev/null | hexdump -C | grep -m1 "01 00 64 aa"
# Divide the left-column byte offset by 512 to get the real sector.
# If it is not 13312, do NOT use the offsets in this guide as-is.
```

#### Check 4 — Confirm platform scripts agree on the offsets

The currently installed sysupgrade scripts encode the same conventions; if they agree, this guide is aligned with upstream:

```sh
grep -rEn "13312|0x680000|mmcblk0boot0|fip" /lib/upgrade/ 2>/dev/null
```

You should see references to `/dev/mmcblk0boot0` (preloader target) and to the FIP offset as either `13312` (decimal sectors) or `0x680000` (decimal bytes 6 815 744 = 13312 × 512).

**Only proceed to Phase 1 if all four checks pass.** If any disagree, stop and figure out why before writing bootloader components.

---

## Phase 1 — Prepare the Mac

### 1.1 Configure ethernet with a static IP (System Settings)

Plug the ethernet cable from your Mac to the router's LAN port. Then:

1. Open **System Settings** (Apple menu → System Settings — on macOS Monterey and earlier this is **System Preferences**).
2. Click **Network** in the sidebar.
3. Select your ethernet interface in the list (often shown as **Ethernet**, **USB 10/100/1G/2.5G LAN**, or similar — pick whichever shows the cable as connected).
4. Click **Details…** (older macOS: select the interface, then look at the right panel directly).
5. Open the **TCP/IP** tab.
6. Set:
   - **Configure IPv4:** Manually
   - **IP Address:** `192.168.1.254`
   - **Subnet Mask:** `255.255.255.0`
   - **Router:** `192.168.1.1`
7. Click **OK**, then **Apply** if prompted.

### 1.2 Turn off Wi-Fi (so traffic to the router goes only over ethernet)

1. Click the **Control Center** icon in the menu bar (or open **System Settings → Wi-Fi**).
2. Toggle **Wi-Fi** off.

You can turn Wi-Fi back on after the flash is complete.

### 1.3 Find your ethernet interface name (for `tcpdump` later)

Open Terminal and run:

```sh
ifconfig | grep -B1 "inet 192.168.1.254"
```

Note the interface name on the line above the `inet 192.168.1.254` line — typical values are `en0`, `en6`, `en11`, `en18`. Wherever this guide says `<iface>`, substitute that name.

### 1.4 Place the official initramfs into the TFTP root

U-Boot on this device requests the filename **without** the `24.10.6-` version prefix, so we copy/rename accordingly:

```sh
sudo mkdir -p /private/tftpboot
sudo chmod 755 /private/tftpboot
cd /private/tftpboot

sudo rm -f *re-cp-03*recovery.itb recovery.itb 2>/dev/null

sudo cp ~/Downloads/immortalwrt-24.10.6-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb \
        /private/tftpboot/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb

sudo chmod 644 /private/tftpboot/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb
sudo chown root:wheel /private/tftpboot/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb
```

Optional compatibility symlinks (some U-Boot variants request alternative names):

```sh
cd /private/tftpboot
sudo ln -sf immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb \
            openwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb
sudo ln -sf immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb \
            recovery.itb
ls -lah /private/tftpboot/
```

The real file should be **~13 MB**. If it shows 85–99 MB, you accidentally placed the custom one — replace it.

### 1.5 Start the macOS built-in TFTP server

```sh
sudo launchctl unload -F /System/Library/LaunchDaemons/tftp.plist 2>/dev/null
sudo launchctl load   -F /System/Library/LaunchDaemons/tftp.plist
```

Local sanity test:

```sh
cd /tmp && rm -f immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb
tftp 192.168.1.254
```

At the `tftp>` prompt:

```text
mode octet
get immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb
quit
```

Confirm:

```sh
ls -lh /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb
```

If macOS built-in TFTP misbehaves with the router (some U-Boot variants choke on it), fall back to a Python TFTP server with progress output.

### 1.6 Watch real TFTP traffic from the router

In a separate Terminal window, leave this running during Phase 4:

```sh
sudo tcpdump -nvvv -i <iface> 'host 192.168.1.1 and udp'
```

You want to see exactly one successful request like:

```text
192.168.1.1.xxxx > 192.168.1.254.69: TFTP RRQ "immortalwrt-mediatek-filogic-jdcloud_re-cp-03-initramfs-recovery.itb"
```

If RRQs repeat in a loop, see Troubleshooting → "TFTP keeps re-requesting".

---

## Phase 2 — Copy Custom Build Files to the Router

From the Mac:

```sh
cd ~/Downloads/openwrt-custom

scp -O \
  immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin \
  immortalwrt-mediatek-filogic-jdcloud_re-cp-03-preloader.bin \
  immortalwrt-mediatek-filogic-jdcloud_re-cp-03-bl31-uboot.fip \
  immortalwrt-mediatek-filogic-jdcloud_re-cp-03-squashfs-sysupgrade.itb \
  root@192.168.1.1:/tmp/
```

On the router, verify hashes against the build artifacts:

```sh
cd /tmp
ls -lah immortalwrt-mediatek-filogic-jdcloud_re-cp-03-*.{bin,fip,itb} 2>/dev/null
sha256sum immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin
sha256sum immortalwrt-mediatek-filogic-jdcloud_re-cp-03-preloader.bin
sha256sum immortalwrt-mediatek-filogic-jdcloud_re-cp-03-bl31-uboot.fip
sha256sum immortalwrt-mediatek-filogic-jdcloud_re-cp-03-squashfs-sysupgrade.itb
```

If any hash mismatches, stop and re-copy. **Do not reboot.**

Do not upload the custom `initramfs-recovery.itb` — it is unused in this flow.

---

## Phase 3 — Flash Bootloader (Custom GPT / BL2 / FIP)

Only run this phase if you are switching to / refreshing this repo's custom layout. If the device is already on this layout and you only want to update packages, skip to Phase 4 + Phase 5.

⚠️ **Do NOT reboot between 3.1, 3.2, and 3.3.** Run all three, then continue to Phase 4. A reboot in the middle (e.g. new GPT but old FIP) can leave the device unbootable.

⚠️ Run this phase from the **real production system** (not initramfs).

⚠️ Do not unplug power during Phase 3.

### 3.1 Write GPT (this repo's custom 2 GB layout)

```sh
cd /tmp

dd if=immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin \
   of=/dev/mmcblk0 bs=512 seek=0 count=34 conv=fsync
sync
```

Optional verify:

```sh
dd if=/dev/mmcblk0 bs=512 count=34 2>/dev/null | sha256sum
sha256sum /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-gpt.bin
# Hashes should match.
```

Note: this writes only the **primary** GPT (LBA 0–33). The backup GPT at the end of disk is left stale — not a problem for OpenWrt boot. You can reconcile it later from the booted system with `sgdisk -e /dev/mmcblk0` if you care.

### 3.2 Write BL2 / preloader to the eMMC boot partition

```sh
echo 0 > /sys/block/mmcblk0boot0/force_ro

# Wipe the first 4 MB of the boot partition so old preloader headers don't linger
dd if=/dev/zero of=/dev/mmcblk0boot0 bs=512 count=8192 conv=fsync

dd if=/tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-preloader.bin \
   of=/dev/mmcblk0boot0 bs=512 conv=fsync
sync
```

Optional verify:

```sh
PRELOADER_SIZE=$(wc -c < /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-preloader.bin)
PRELOADER_SECTORS=$(( (PRELOADER_SIZE + 511) / 512 ))

dd if=/dev/mmcblk0boot0 bs=512 count=$PRELOADER_SECTORS 2>/dev/null | sha256sum
sha256sum /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-preloader.bin
```

### 3.3 Write FIP (BL31 + U-Boot) at sector 13312

```sh
# Wipe the 4 MB FIP slot first
dd if=/dev/zero of=/dev/mmcblk0 bs=512 seek=13312 count=8192 conv=fsync

dd if=/tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-bl31-uboot.fip \
   of=/dev/mmcblk0 bs=512 seek=13312 conv=fsync
sync
```

Optional verify:

```sh
FIP_SIZE=$(wc -c < /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-bl31-uboot.fip)
FIP_SECTORS=$(( (FIP_SIZE + 511) / 512 ))

dd if=/dev/mmcblk0 bs=512 skip=13312 count=$FIP_SECTORS 2>/dev/null | sha256sum
sha256sum /tmp/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-bl31-uboot.fip
```

### 3.4 Final sync — do NOT reboot expecting normal boot

```sh
sync
echo 3 > /proc/sys/vm/drop_caches
sync
```

The current rootfs/overlay no longer matches the new GPT, so a normal reboot will not work. Continue straight to Phase 4 (TFTP recovery).

---

## Phase 4 — Boot the Official Initramfs over TFTP

Confirm on the Mac:

- TFTP is running (`sudo launchctl list | grep tftp`).
- The **official** initramfs is in `/private/tftpboot/` under the right filename.
- The `tcpdump` window from 1.6 is still running.

On the router, trigger the reboot:

```sh
sync
reboot -f
```

Then physically force TFTP recovery:

1. Cut power to the router.
2. Wait about 10 seconds.
3. Hold the reset button.
4. Reapply power **while still holding reset**.
5. Release reset after the TFTP RRQ shows up in `tcpdump`, or after about 5–10 seconds.

In `tcpdump` you should see one RRQ for the official recovery filename, then a transfer to completion (~13 MB). Recovery boots quickly after that.

Verify recovery is up (in a new Terminal window):

```sh
ping 192.168.1.1
ssh root@192.168.1.1
df -h
mount
```

In initramfs, `/` is `tmpfs` — that is expected at this stage.

---

## Phase 5 — Flash the Custom Sysupgrade From Recovery

### 5.1 Stop the TFTP server

So the next reboot does not accidentally re-enter recovery:

```sh
sudo launchctl unload -F /System/Library/LaunchDaemons/tftp.plist 2>/dev/null
```

(If you used a Python TFTP server instead, `Ctrl+C` it.)

Optional — move the recovery file out of the TFTP root:

```sh
cd /private/tftpboot
sudo mkdir -p disabled
sudo mv *re-cp-03*recovery.itb recovery.itb disabled/ 2>/dev/null
```

### 5.2 Upload the custom sysupgrade into recovery

```sh
cd ~/Downloads/openwrt-custom

scp -O immortalwrt-mediatek-filogic-jdcloud_re-cp-03-squashfs-sysupgrade.itb \
       root@192.168.1.1:/tmp/custom-sysupgrade.itb
```

On the router:

```sh
ls -lh /tmp/custom-sysupgrade.itb
sha256sum /tmp/custom-sysupgrade.itb
```

### 5.3 Validate the image before flashing

```sh
sysupgrade -T /tmp/custom-sysupgrade.itb
```

If this reports incompatible device, wrong metadata, or image errors, **do not** force with `-F` unless you have TTL serial and a recovery plan.

### 5.4 Clear pstore (Critical Point 3)

```sh
rm -f /sys/fs/pstore/*
sync
```

### 5.5 Flash with a clean overlay

```sh
sysupgrade -n -v /tmp/custom-sysupgrade.itb
```

`-n` discards the existing overlay — that is intentional; the config was already backed up in 0.2. SSH will disconnect. Wait several minutes. **Do not unplug power.**

---

## Phase 6 — Post-flash Verification

```sh
ssh root@192.168.1.1     # or your custom LAN IP
```

If SSH complains about a changed host key:

```sh
ssh-keygen -R 192.168.1.1
```

Confirm you are in the real production system, not initramfs:

```sh
df -h
mount
cat /etc/openwrt_release
```

Success looks like:

```text
/dev/root on /rom type squashfs
/dev/fitrw on /overlay type f2fs
overlayfs:/overlay on / type overlay
```

Failure (still in recovery) looks like:

```text
tmpfs on / type tmpfs
```

If you see the failure pattern, go to Phase 7.

Then set the root password:

```sh
passwd
```

You can now turn Wi-Fi back on, and revert your Mac's ethernet to **Configure IPv4: Using DHCP** in System Settings → Network.

---

## Phase 7 — If It Still Boots Into Initramfs

If LuCI shows a banner saying the system is running in initramfs mode, then U-Boot is still being forced into recovery. From an SSH shell **inside initramfs**:

```sh
rm -f /sys/fs/pstore/*
sync
reboot
```

Also confirm:

- TFTP server is **stopped** on the Mac.
- No recovery file is present in `/private/tftpboot/` (or it has been moved to `disabled/`).

After reboot, recheck `df -h` / `mount`. If still in initramfs:

```sh
# Re-upload and re-flash
scp -O ~/Downloads/openwrt-custom/immortalwrt-mediatek-filogic-jdcloud_re-cp-03-squashfs-sysupgrade.itb \
       root@192.168.1.1:/tmp/custom-sysupgrade.itb

sysupgrade -T /tmp/custom-sysupgrade.itb
rm -f /sys/fs/pstore/*
sync
sysupgrade -n -v /tmp/custom-sysupgrade.itb
```

Use the CLI, not LuCI — error messages are clearer.

---

## Troubleshooting

### TFTP keeps re-requesting the recovery file in a loop

Symptom in `tcpdump` or the TFTP server log:

```text
Done. Sent ...
RRQ from ...
Sending ...
Done. Sent ...
... (repeats)
```

This is almost never a TFTP transport problem. It means U-Boot received the file but failed to boot it. By far the most common cause on this device: **the served `initramfs-recovery.itb` is the huge custom one (~85–99 MB) instead of the official one (~13 MB)**.

Fix: replace the file in `/private/tftpboot/` with the official initramfs from the URL above, keeping the same filename U-Boot is requesting in `tcpdump`.

### Router pings but SSH/HTTP do not respond

U-Boot answers ICMP even when Linux has not booted. Ping ≠ recovery is up. Check actual TCP ports:

```sh
nc -vz 192.168.1.1 22
nc -vz 192.168.1.1 80
```

### `sysupgrade` looks fine but reboot lands in initramfs

Clear `pstore` — see Phase 7.

### Need to know the exact filename U-Boot is asking for

```sh
sudo tcpdump -nvvv -i <iface> 'host 192.168.1.1 and udp'
# look for: RRQ "<filename>"
```

Then place the official recovery file in `/private/tftpboot/` under exactly that name (a symlink works).

### Hash mismatch after `scp`

Stop. Do not reboot. Re-copy and re-verify. Never proceed with a mismatched bootloader file.

### Mac cannot reach `192.168.1.1`

- Verify in **System Settings → Network** that the ethernet interface shows the static IP `192.168.1.254` and is connected.
- Verify Wi-Fi is off.
- Try unplugging and re-plugging the ethernet cable.
- Confirm with `ifconfig <iface>` that `inet 192.168.1.254` is present.

---

## Phase 8 — eMMC Free Space (optional, informational)

The boot/firmware/overlay region uses only a small fraction of the 128 GB eMMC; that's normal. Two safer options if you want to use the rest:

1. Bake the desired layout into a custom GPT in the build (this repo already does so for rootfs — `CONFIG_TARGET_ROOTFS_PARTSIZE=2048`).
2. Create a separate data partition in free space and mount it at `/mnt/data`, `/opt`, `/opt/docker`, etc. — without resizing rootfs.

Inspect current layout:

```sh
cat /proc/partitions
fdisk -l /dev/mmcblk0
df -h
```

Avoid resizing rootfs/overlay live with `parted` / `resize2fs` tricks; redo the build instead.

---

## Quick Reference

| Step | Command | Where |
|---|---|---|
| Confirm real system | `df -h; mount` | router |
| Backup config | `sysupgrade -b /tmp/backup-config.tar.gz` | router |
| Backup GPT | `dd if=/dev/mmcblk0 of=/tmp/backup-gpt.bin bs=512 count=34` | router |
| Backup preloader | `dd if=/dev/mmcblk0boot0 of=/tmp/backup-preloader.bin bs=512 count=2048` | router |
| Backup FIP | `dd if=/dev/mmcblk0 of=/tmp/backup-fip.bin bs=512 skip=13312 count=8192` | router |
| Mac static IP | System Settings → Network → Ethernet → Details → TCP/IP → Manually | Mac |
| Start TFTP | `sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist` | Mac |
| Watch TFTP | `sudo tcpdump -nvvv -i <iface> 'host 192.168.1.1 and udp'` | Mac |
| Stop TFTP | `sudo launchctl unload -F /System/Library/LaunchDaemons/tftp.plist` | Mac |
| Write GPT | `dd if=...gpt.bin of=/dev/mmcblk0 bs=512 seek=0 count=34 conv=fsync` | router |
| Write BL2 | `dd if=...preloader.bin of=/dev/mmcblk0boot0 bs=512 conv=fsync` | router |
| Write FIP | `dd if=...bl31-uboot.fip of=/dev/mmcblk0 bs=512 seek=13312 conv=fsync` | router |
| Boot recovery | power-cycle while holding reset; serve official initramfs over TFTP | both |
| Test sysupgrade | `sysupgrade -T /tmp/custom-sysupgrade.itb` | recovery |
| **Clear pstore** | `rm -f /sys/fs/pstore/*; sync` | recovery |
| Flash final firmware | `sysupgrade -n -v /tmp/custom-sysupgrade.itb` | recovery |
| Verify success | `overlayfs:/overlay on / type overlay` | router |

---

## The One Rule To Remember

```text
TFTP recovery       = OFFICIAL small initramfs (~13 MB) from downloads.immortalwrt.org
Permanent firmware  = THIS REPO's squashfs-sysupgrade.itb (from GitHub Actions artifacts)
Bootloader trio     = THIS REPO's gpt.bin + preloader.bin + bl31-uboot.fip (custom 2 GB layout)
After sysupgrade    = rm -f /sys/fs/pstore/*    ← do not skip this
```
