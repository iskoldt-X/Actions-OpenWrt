# Actions-OpenWrt

ImmortalWrt firmware builds for three devices, built on GitHub Actions.

[![x86-64](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-x86-64-generic.yml/badge.svg)](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-x86-64-generic.yml)
[![RE-CP-03](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-filogic-re-cp-03.yml/badge.svg)](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-filogic-re-cp-03.yml)
[![RE-SS-01](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-ipq60xx-re-ss-01.yml/badge.svg)](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-ipq60xx-re-ss-01.yml)

## Builds

| Workflow | Target | Source tree | Config | Release tag |
| --- | --- | --- | --- | --- |
| `build-x86-64-generic.yml` | `x86/64` generic | `immortalwrt/immortalwrt` `openwrt-24.10` | `x86-64-generic.config` | `ImmortalWrt-x86-64-*` |
| `build-filogic-re-cp-03.yml` | `mediatek/filogic`, JDCloud RE-CP-03 | `immortalwrt/immortalwrt` `openwrt-24.10` | `filogic-re-cp-03.config` | `ImmortalWrt-RE-CP-03-*` |
| `build-ipq60xx-re-ss-01.yml` | `qualcommax/ipq60xx`, JDCloud RE-SS-01 | `VIKINGYFY/immortalwrt` `main` | `ipq60xx-re-ss-01.config` | `ImmortalWrt-RE-SS-01-*` |

Each of the three files above only supplies parameters. Every build step lives
in `_build.yml`, which they call through `workflow_call`, so a fix is made once
rather than three times.

All three run on `ubuntu-24.04`, can be started from the Actions tab, and are
also built weekly on Monday (03:00, 04:00 and 05:00 UTC -- staggered so they do
not all clone and fetch in the same minute). Each build uploads the firmware as
a workflow artifact and publishes a release named after its tag.

Old releases are pruned per device: the newest release of each device is always
kept, and the rest are removed after 30 days. Without that scoping the pruner
deletes every release in the repository by age, so one device's weekly build
would take another device's firmware with it.

## Xray binary

All three workflows download the official static `Xray-core` binary and place it
at `/usr/bin/xray` inside the image, together with the version string at
`/etc/xray.version`. The upstream binaries are built with `CGO_ENABLED=0`, so
they run unmodified against musl. The archive checksum is verified against the
published `.dgst` file and the architecture of the extracted binary is asserted
before it is added to the image. The x86-64 build additionally executes the
binary and asserts the version it reports; the two aarch64 builds cannot, since
the runner is x86-64.

By default the workflows track the newest tag, including pre-releases. Note that
the GitHub `releases/latest` endpoint skips pre-releases and can lag far behind,
so `releases?per_page=1` is used instead.

To pin a specific version, set the repository variable `XRAY_VERSION` to a
version without the leading `v`, for example `26.9.9`. Leave it unset to keep
tracking the newest tag.

Keep `CONFIG_PACKAGE_xray-core` out of the `.config` files. The feed package
installs its own `/usr/bin/xray` and would overwrite the injected binary.

## Repository layout

- `_build.yml` is the shared pipeline; the three `build-*.yml` files are callers.
- `*.config` are seed configs copied to `openwrt/.config`; `make defconfig`
  expands them. Two lines are asserted afterwards, the target and
  `luci-app-openclash`, so an emptied config fails the build instead of
  publishing a stock image.
- `files/` is copied into the image root before the build. It enables BBR, sets
  the LuCI language to English, and receives the Xray binary during the build.
- `docs/` holds device notes: flashing and storage guides for the
  JDCloud RE-CP-03, and research notes on MT7986 flow offload.

## Credits

Originally based on the [Actions-OpenWrt][template] template.

[template]: https://github.com/P3TERX/Actions-OpenWrt

## License

[MIT](LICENSE) (c) [P3TERX](https://p3terx.com)
