# Packaging files for the rsshterm `.deb` (and tarball)

| File here | Installs to |
|---|---|
| `dev.rsshterm.RSSHTerm.desktop` | `/usr/share/applications/dev.rsshterm.RSSHTerm.desktop` |
| `dev.rsshterm.RSSHTerm.metainfo.xml` | `/usr/share/metainfo/dev.rsshterm.RSSHTerm.metainfo.xml` |
| `icons/hicolor/<N>x<N>/apps/dev.rsshterm.RSSHTerm.png` (512, 256, 128, 64, 48, 32, 16) | `/usr/share/icons/hicolor/<N>x<N>/apps/dev.rsshterm.RSSHTerm.png` |
| (the binary) | `/usr/bin/rsshterm` |

In short: copy `icons/` to `/usr/share/icons/` as is. The file names follow the app id `dev.rsshterm.RSSHTerm`
(GApplication id, desktop file name, icon name and AppStream id are the same, so GNOME matches the window to its
launcher). dpkg triggers refresh the icon cache and the desktop database; no maintainer scripts are needed.

The tarball can carry the same tree under `share/` next to `bin/`.

- `render-icons.sh`: the PNGs from the one app logo, `apple/RSSH/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
  (ImageMagick); a new logo regenerates every size. The PNGs are committed. The AppImage takes the 256 px one as
  `.DirIcon` / `dev.rsshterm.RSSHTerm.png`. No SVG: the logo is a bitmap.
- `validate.sh`: desktop-file-validate, appstreamcli validate, every icon present (run by
  `make test-desktop-linux-app`).
