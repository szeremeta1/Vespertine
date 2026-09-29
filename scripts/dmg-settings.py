# dmgbuild layout for Vespertine's installer disk image.
# Coordinates must match scripts/make-dmg-background.swift (window 660×420 pt, icon centres).
#   dmgbuild -s scripts/dmg-settings.py -D app=<path/Vespertine.app> -D background=<dir/background.png> "Vespertine X" out.dmg
import os

app = defines["app"]            # noqa: F821  (injected by dmgbuild)
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "APFS"
compression_level = 9
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Vespertine.app"]

# Finder window
background = background
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
show_icon_preview = False

# Icon view
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {
    os.path.basename(app): (180, 212),
    "Applications": (480, 212),
}
