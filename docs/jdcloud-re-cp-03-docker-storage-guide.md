# ImmortalWrt RE-CP-03 (AX6000) — Use Extra eMMC Space for Docker

This guide shows how to turn the unused space on the 128 GB eMMC into a 100 GB ext4 partition, mount it at `/opt`, and point Docker at `/opt/docker` so containers and images stop filling up the small OpenWrt overlay.

Tested on JDCloud RE-CP-03 / AX6000 with ImmortalWrt.

## Goal

After this setup:

```text
/overlay      stays on the normal system writable area
/opt          uses the new 100 GB ext4 partition
/opt/docker   stores Docker images, containers, and volumes
```

This avoids filling up the small OpenWrt overlay.

---

## ⚠️ Important Warnings

**Do not delete or modify these existing partitions:**

```text
/dev/mmcblk0p1
/dev/mmcblk0p2
/dev/mmcblk0p3
/dev/mmcblk0p4
/dev/mmcblk0p5
/dev/mmcblk0p128
```

- Only create a new partition in the **free space after `p5`**.
- Do **not** format the whole disk `/dev/mmcblk0`.
- If you later flash a custom `gpt.bin`, make sure the new `gpt.bin` preserves `/dev/mmcblk0p6`, otherwise the Docker data partition may be lost.

---

## 1. Install Required Tools

SSH into the router:

```sh
ssh root@192.168.1.1
```

Then run:

```sh
opkg update
opkg install fdisk cfdisk block-mount e2fsprogs
```

Verify:

```sh
grep ext4 /proc/filesystems
which mkfs.ext4
```

If you see something like:

```text
ext4
/usr/sbin/mkfs.ext4
```

you can continue.

---

## 2. Check the Current Partition Table

```sh
fdisk -l /dev/mmcblk0
cat /proc/partitions
```

Before creating the new partition, you should see something like:

```text
/dev/mmcblk0p1       512K
/dev/mmcblk0p2         2M
/dev/mmcblk0p3         4M
/dev/mmcblk0p4        32M
/dev/mmcblk0p5         2G
/dev/mmcblk0p128       4M
```

You may also see GPT warnings such as:

```text
GPT PMBR size mismatch
The backup GPT table is corrupt
The backup GPT table is not on the end of the device
```

This is expected if only the primary GPT was previously written. `cfdisk` will fix this when it writes the updated partition table.

---

## 3. Create a New 100 GB Partition With `cfdisk`

```sh
cfdisk /dev/mmcblk0
```

Inside `cfdisk`:

1. Select the **free space** after `/dev/mmcblk0p5`.
2. Choose **New**.
3. Enter the size, e.g. `100G`.
4. Keep the type as **Linux filesystem**.
5. Choose **Write**.
6. Type `yes` to confirm.
7. Choose **Quit**.

Then sync and reboot:

```sh
sync
reboot
```

---

## 4. Confirm the New Partition Exists

After reboot, SSH back in:

```sh
ssh root@192.168.1.1
```

Check the partition table:

```sh
fdisk -l /dev/mmcblk0
cat /proc/partitions
```

You should now see a new line for `/dev/mmcblk0p6`, for example:

```text
/dev/mmcblk0p6   4325376 214040575 209715200  100G  Linux filesystem
```

---

## 5. Format the New Partition as ext4

Confirm the partition is `/dev/mmcblk0p6`, then:

```sh
mkfs.ext4 -F -L optdata /dev/mmcblk0p6
sync
```

The command should print a new filesystem UUID, for example:

```text
Filesystem UUID: 38561966-0dbb-4a1c-807d-bebda3a02fc5
```

---

## 6. Mount the New Partition via LuCI

Open the router web admin page in a browser:

```text
http://192.168.1.1
```

Go to **System → Mount Points**.

Click **Generate Config**

Find the new ext4 partition. Select it and then click **Add**.

Add or edit a mount point with these values:

| Field | Value |
|---|---|
| Device | `/dev/mmcblk0p6` |
| Mount point | `/opt` |
| Filesystem | `ext4` |
| Enabled | yes |

Save and apply, then reboot the router.

---

---

## 7. Create the Docker Directory

```sh
mkdir -p /opt/docker
```


## 8. Verify That `/opt` Uses the 100 GB Partition

After reboot, SSH back in and run:

```sh
df -h
mount | grep ' /opt '
df -h /opt /opt/docker
```

Expected:

```text
/dev/mmcblk0p6    ~100G    ...    /opt
/dev/mmcblk0p6    ~100G    ...    /opt/docker
```
---

## 9. Restart Docker

Once `/opt` is correctly mounted to `/dev/mmcblk0p6`:

```sh
/etc/init.d/dockerd restart
```

Or, if it was stopped:

```sh
/etc/init.d/dockerd start
```

Confirm Docker is now using the new partition:

```sh
docker info 2>/dev/null | grep -i "Docker Root Dir"
```

Expected:

```text
Docker Root Dir: /opt/docker
```

---

## Final Expected Layout

After everything is done, the storage layout should look like:

```text
/rom          system read-only image
/overlay      normal OpenWrt writable overlay
/opt          100 GB ext4 partition
/opt/docker   Docker data directory
```

Example from `mount` / `df -h`:

```text
/dev/root        /rom
/dev/fitrw       /overlay
/dev/mmcblk0p6   /opt
/dev/mmcblk0p6   /opt/docker
```

---

## Maintenance Note

A normal `sysupgrade` should only affect the firmware area, not `/opt` or the Docker data partition.

However, if you flash a new **custom `gpt.bin`**, verify that the new GPT keeps `/dev/mmcblk0p6` in place. If the new layout drops or relocates that partition, the Docker data is lost. Before flashing a new `gpt.bin`:

```sh
# Inspect the new gpt.bin to see what partitions it defines
parted /tmp/new-gpt.bin unit s print
# or
sgdisk -p /tmp/new-gpt.bin
```

If `p6` (or an equivalent 100 GB partition) is not present, back up `/opt` first or rebuild your firmware with a `gpt.bin` that preserves it.
