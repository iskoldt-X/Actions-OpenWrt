# Actions-OpenWrt

ImmortalWrt firmware builds for three devices, built on GitHub Actions.

[![x86](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-immortalwrt-anti-ssr-x86.yml/badge.svg)](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-immortalwrt-anti-ssr-x86.yml)
[![AX6000](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-immortalwrt-SSR-AX6000.yml/badge.svg)](https://github.com/iskoldt-X/Actions-OpenWrt/actions/workflows/build-immortalwrt-SSR-AX6000.yml)

## Builds

| Workflow | Target | Source tree | Config |
| --- | --- | --- | --- |
| `build-immortalwrt-anti-ssr-x86.yml` | `x86/64` generic | `immortalwrt/immortalwrt` `openwrt-24.10` | `immortalwrt-anti-ssr-x86.config` |
| `build-immortalwrt-SSR-AX6000.yml` | `mediatek/filogic`, JDCloud RE-CP-03 | `immortalwrt/immortalwrt` `openwrt-24.10` | `immortalwrt-AX6000.config` |
| `build-immortalwrt-AX1800.yml` | `qualcommax/ipq60xx`, JDCloud RE-SS-01 | `VIKINGYFY/immortalwrt` `main` | `immortalwrt-AX1800.config` |

All three run on `ubuntu-24.04` and can be started manually from the Actions
tab (`workflow_dispatch`) or by `repository_dispatch`. The x86 and AX6000
builds also run weekly, Monday 03:00 UTC.

Each build uploads the firmware as a workflow artifact and publishes a
release tagged with the build date.

## Xray binary

The x86 and AX6000 workflows download the official static `Xray-core` binary
and place it at `/usr/bin/xray` inside the image, together with the version
string at `/etc/xray.version`. The upstream binaries are built with
`CGO_ENABLED=0`, so they run unmodified against musl. The archive checksum is
verified against the published `.dgst` file and the architecture of the
extracted binary is asserted before it is added to the image.

By default the workflows track the newest tag, including pre-releases. Note
that the GitHub `releases/latest` endpoint skips pre-releases and can lag far
behind, so `releases?per_page=1` is used instead.

To pin a specific version, set the repository variable `XRAY_VERSION` to a
version without the leading `v`, for example `26.9.9`. Leave it unset to keep
tracking the newest tag.

Keep `CONFIG_PACKAGE_xray-core` out of the `.config` files. The feed package
installs its own `/usr/bin/xray` and would overwrite the injected binary.

## Repository layout

- `files/` is copied into the image root before the build. It currently
  enables BBR and sets the LuCI language to English.
- `feeds.conf.default` replaces the feed list of the cloned source tree.
- `docs/` holds device notes: flashing and storage guides for the
  JDCloud RE-CP-03, and research notes on MT7986 flow offload.

## Credits

Originally based on the [Actions-OpenWrt][template] template.

[template]: https://github.com/P3TERX/Actions-OpenWrt

## License

[MIT](LICENSE) (c) [P3TERX](https://p3terx.com)
