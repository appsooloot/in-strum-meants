# dmgbuild settings for the In Strum Meants installer window.
import os.path

app = defines["app"]
background = defines["background"]

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (165, 190), "Applications": (495, 190)}

window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
show_icon_preview = False
include_icon_view_settings = True
