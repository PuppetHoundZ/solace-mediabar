Self-contained single-file manager. Generates all required files on Install:

* media-control-solace  (GTK3 + gtk-layer-shell Python GUI) -> ~/.local/bin/
* Desktop shortcut + SVG icon                               -> ~/.local/share/

Do not run as root.


-- WHAT THIS DOES -----------------------------------------------------------

Installs apt deps, writes the GUI Python script, desktop shortcut, and SVG
icon. Desktop icon launches GUI directly via:
  Exec=python3 ~/.local/bin/media-control-solace
Same pattern as AirPlay Solace and Cava Solace - confirmed working.
GUI has a single-instance guard: second launch exits silently if already
running. Manager menu option 3 opens/closes via pgrep/kill.
