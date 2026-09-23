# Artwork

Original AppKit vector artwork, distributed under the project's GPL-3.0-or-later license.
No downloaded product photos or vendor logos are included.

Regenerate the PNGs and multi-resolution ICNS from the repository root:

```sh
swift scripts/make-icons.swift .build/icon-artwork
iconutil -c icns .build/icon-artwork/AppIcon.iconset -o Assets/AppIcon.icns
cp .build/icon-artwork/AppIcon.png .build/icon-artwork/StatusIconTemplate.png Assets/
```
