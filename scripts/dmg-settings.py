# dmgbuild settings for the UniPlayer disk image.
#
# This exists because Tauri's own dmg target cannot work on CI: bundle_dmg.sh
# arranges the window by driving Finder over AppleScript, and a headless runner
# has no Finder session — the step ran, reported nothing, and shipped a disk
# image with no .DS_Store at all, which Finder then renders as a plain folder.
# dmgbuild writes the .DS_Store itself, so the layout survives.
#
# No background image: a plain window with the app beside the Applications
# link. icon_locations centre the pair in window_rect's content area.

import os.path

app = defines.get("app", "src-tauri/target/release/bundle/macos/UniPlayer.app")
appname = os.path.basename(app)

# UDZO over the better-compressing ULFO: this is the artifact people download
# once, and zlib is readable by every macOS that can run the app.
format = "UDZO"
size = None

files = [app]
symlinks = {"Applications": "/Applications"}
icon = "src-tauri/icons/icon.icns"

# Finder's WindowBounds is the window *frame*, not its content: measured on
# macOS 26, the title bar takes 32 pt off the top and a path bar another 28 at
# the bottom. 432 is 400 of content + the title bar.
window_rect = ((200, 200), (660, 432))
default_view = "icon-view"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 180

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 16
icon_size = 128

icon_locations = {
    appname: (170, 205),
    "Applications": (490, 205),
}
