# Artwork

Original AppKit vector artwork, distributed under the project's GPL-3.0-or-later license.
No downloaded product photos or vendor logos are included.

Regenerate the PNGs and multi-resolution ICNS from the repository root:

```sh
swift scripts/make-icons.swift .build/icon-artwork
iconutil -c icns .build/icon-artwork/AppIcon.iconset -o Assets/AppIcon.icns
cp .build/icon-artwork/AppIcon.png Assets/
```

The menu-bar glyph is loaded from macOS SF Symbols at runtime (`airpodspro`). It is
not copied into the bundle and is not part of the original GPL artwork above.
