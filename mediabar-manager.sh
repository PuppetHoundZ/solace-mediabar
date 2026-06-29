#!/usr/bin/env bash
# =============================================================================
# mediabar-manager.sh
# Media Control Solace - MPRIS Media Control Bar - Manager
# Version: 1.2.0
# Status: 🟢 GOLD - confirmed working on real hardware, locked baseline
# Last updated: 2026-06-23
#
# Self-contained single-file manager. Generates all required files on Install:
#   - media-control-solace  (GTK3 + gtk-layer-shell Python GUI) -> ~/.local/bin/
#   - Desktop shortcut + SVG icon                               -> ~/.local/share/
#
# No companion files required. Do NOT run as root.
# =============================================================================

# =============================================================================
# AI REFERENCE NOTES - read before making any changes.
#
# -- WHAT THIS DOES -----------------------------------------------------------
#   Installs apt deps, writes the GUI Python script, desktop shortcut, and SVG
#   icon. Desktop icon launches GUI directly via:
#     Exec=python3 ~/.local/bin/media-control-solace
#   Same pattern as AirPlay Solace and Cava Solace - confirmed working.
#   GUI has a single-instance guard: second launch exits silently if already
#   running. Manager menu option 3 opens/closes via pgrep/kill.
#
# -- KEY PATHS ----------------------------------------------------------------
#   ~/.local/bin/media-control-solace                         GUI (the bar)
#   ~/.local/share/applications/media-control-solace.desktop
#   ~/.local/share/icons/hicolor/scalable/apps/media-control-solace.svg
#   ~/.config/media-control-solace/state.conf                 scale + dock/float
#   /dev/shm/media-control-solace-art/                        RAM art cache
#   ~/.local/share/mediabar-manager/                          rollback state dir
#
# -- ENVIRONMENT --------------------------------------------------------------
#   Pi 4, Pi OS Trixie arm64, labwc Wayland. 800x480 touchscreen primary +
#   1080p HDMI secondary (not always connected). PipeWire + WirePlumber.
#   Never touch PipeWire config. No systemd units, no autostart.
#
# -- POSITIONING --------------------------------------------------------------
#   Uses gtk-layer-shell (plain GTK3 cannot position windows on Wayland).
#   Width locked at 800px. Layer=TOP, exclusive_zone=0.
#   _select_target_monitor() pins to 800x480 monitor BEFORE realization.
#   _initial_position() fires via GLib.idle_add AFTER show_all() - margins
#   must be set after surface realization or the compositor ignores them.
#   Dock mode: BOTTOM anchor, margin_bottom=0 - flush to screen bottom,
#   no height arithmetic. Float mode: TOP+LEFT anchor, drag via grip handle.
#   _on_toggle_dock_float() switches anchors between modes.
#
# -- PGREP - CRITICAL ---------------------------------------------------------
#   Always: pgrep -f "python3.*$GUI_SCRIPT"
#   Never bare pgrep -f "$GUI_SCRIPT" - substring-matches its own process name.
#
# -- DO NOT RE-ADD WITHOUT REQUEST --------------------------------------------
#   - Toggle-wrapper script: replaced by direct launch + single-instance guard.
#     Bare-path pgrep self-matched wrapper filename; icon never launched.
#   - Drag-to-resize: deliberate removal; buttons-only at 36-44px is cleaner.
#   - Always-on-top: requires rc.xml edits, ruled out.
#   - Minimize button: layer-shell windows have no taskbar presence.
#
# -- DEPENDENCIES -------------------------------------------------------------
#   python3-cairo AND python3-gi-cairo are both required (separate packages).
#   python3-cairo = standalone pycairo for `import cairo`.
#   python3-gi-cairo = GObject integration glue.
#
# -- ROLLBACK -----------------------------------------------------------------
#   ERR trap captures $BASH_COMMAND + $LINENO. EXIT trap passes real "$?"
#   directly - not a cached ERR variable (explicit exit calls skip ERR trap).
#   Never end a function with bare `[[ -f x ]] && cmd` - use if/fi + return 0.
#
# -- METADATA + VOLUME --------------------------------------------------------
#   playerctl --follow in background thread. self._metadata_proc terminated
#   in _on_close to prevent orphaned processes.
#   wpctl set-volume -l 1.0 (caps at 100%). wpctl set-mute toggle for mute.
#
# -- COLORS -------------------------------------------------------------------
#   neutral #1a2530 | primary/play #1a3a22 | danger/close #3a1a1a
#   volume  #3a2e1a | window bg rgba(13,15,18,0.72) | frosted = pre-blended
#
# -- UI IMPLEMENTATION --------------------------------------------------------
#   Fully transparent panel background. Dark frosted border box behind
#   now-playing text only (Gtk.EventBox + .text-bg CSS). Label padded via
#   set_margin_start/end(10) - CSS padding on EventBox silently ignored by GTK3.
#   Album art: RoundedArt (Gtk.DrawingArea + Cairo rounded-rect clip).
#   Buttons: Unicode text labels (<<  > ||  >>  vol-  mute  vol+  smaller larger  Float/Dock  X).
#   CSS rebuilt and reloaded on every scale change via build_css(scale).
#   CSS loaded at init - provider starts empty otherwise (renders grey on launch).
#
# -- VERSION HISTORY ----------------------------------------------------------
#   v1.0.0  Initial release - GTK3 layer-shell media bar
#   v1.0.5  Removed drag-to-resize; float-mode grip kept for move only
#   v1.1.0  Replaced toggle-wrapper with direct launch + single-instance guard
#   v1.1.5  BOTTOM anchor dock mode; pgrep self-match bug fixed
#   v1.1.9  GOLD baseline - Cairo art clip; all positioning confirmed on hw
#   v1.2.0  GOLD - Rebrand "Media Solace" -> "Media Control Solace"; all slugs/paths
#           updated (binary, desktop, icon, config dir, art cache);
#           fixed em-dash UTF-8 in echo strings causing bash EOF parse error
# =============================================================================

set -Eeuo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()       { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()       { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()      { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
error_noexit() { echo -e "${RED}[ERROR]${NC} $*"; }
step()       { echo -e "\n${CYAN}── $* ──${NC}"; }
divider()    { echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"; }
print_ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
print_info() { echo -e "  ${CYAN}•${NC}  $*"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
INSTALL_BIN="$HOME/.local/bin"
GUI_SCRIPT="$INSTALL_BIN/media-control-solace"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/media-control-solace.desktop"
ICON_FILE="$ICON_DIR/media-control-solace.svg"
APP_CONFIG_DIR="$HOME/.config/media-control-solace"
APP_CONFIG_FILE="$APP_CONFIG_DIR/state.conf"
ART_CACHE_DIR="/dev/shm/media-control-solace-art"

# ── Sanity check ──────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] && error "Do not run this script as root."

mkdir -p "$INSTALL_BIN" "$ICON_DIR" "$DESKTOP_DIR" "$APP_CONFIG_DIR"

# ── Rollback / crash recovery ─────────────────────────────────────────────────
# State files live in $HOME/.local/share/mediabar-manager/ — writable,
# user-owned, survives reboots for crash detection (not /tmp).
STATE_DIR="$HOME/.local/share/mediabar-manager"
PARTIAL_MARKER="$STATE_DIR/install.partial"
BACKUP_GUI="$STATE_DIR/media-control-solace.backup"
mkdir -p "$STATE_DIR"

_ROLLBACK_OP=""

_rollback_cleanup() {
    local exit_code="${1:-0}"
    local op="$_ROLLBACK_OP"

    if [[ -f "$PARTIAL_MARKER" && "$exit_code" -ne 0 ]]; then
        echo ""
        if [[ -n "$_FAILED_COMMAND" ]]; then
            error_noexit "Failed command (exit $exit_code), line ${_FAILED_LINE:-?}: ${_FAILED_COMMAND}"
        fi
        warn "Operation '${op}' did not complete - rolling back changes..."

        if [[ -f "$BACKUP_GUI" ]]; then
            cp -f "$BACKUP_GUI" "$GUI_SCRIPT" && info "Restored: $GUI_SCRIPT" || \
                warn "Could not restore $GUI_SCRIPT - run Install again."
            rm -f "$BACKUP_GUI"
        elif [[ "$op" == "install" && -f "$GUI_SCRIPT" ]]; then
            rm -f "$GUI_SCRIPT" && info "Removed partial GUI script."
        fi

        rm -f "$PARTIAL_MARKER"
        echo ""
        warn "Rollback complete. Your system is back to its previous state."
        warn "Fix the issue above then run this script again."
    elif [[ -f "$PARTIAL_MARKER" && "$exit_code" -eq 0 ]]; then
        rm -f "$PARTIAL_MARKER" "$BACKUP_GUI"
    fi
}

_FAILED_COMMAND=""
_FAILED_LINE=""
trap '_FAILED_COMMAND="$BASH_COMMAND"; _FAILED_LINE="$LINENO"' ERR
trap '_rollback_cleanup "$?"' EXIT
trap 'echo ""; warn "Interrupted."; exit 130' INT TERM HUP

_rollback_begin() {
    _ROLLBACK_OP="$1"
    echo "$1" > "$PARTIAL_MARKER"
    if [[ -f "$GUI_SCRIPT" ]]; then
        cp -f "$GUI_SCRIPT" "$BACKUP_GUI"
    fi
    return 0
}

_rollback_end() {
    _ROLLBACK_OP=""
    rm -f "$PARTIAL_MARKER" "$BACKUP_GUI"
}

_check_partial_state() {
    if [[ ! -f "$PARTIAL_MARKER" ]]; then
        return
    fi
    local op
    op=$(cat "$PARTIAL_MARKER")
    echo ""
    warn "Previous '${op}' did not complete (power loss or crash?) - auto-restoring..."

    if [[ -f "$BACKUP_GUI" ]]; then
        cp -f "$BACKUP_GUI" "$GUI_SCRIPT" && info "Restored: $GUI_SCRIPT"
        rm -f "$BACKUP_GUI"
    elif [[ -f "$GUI_SCRIPT" ]]; then
        rm -f "$GUI_SCRIPT"
        info "Removed incomplete GUI script."
    fi

    rm -f "$PARTIAL_MARKER"
    echo ""
    info "System restored to clean state. Select '${op}' from the menu to try again."
    echo ""
}

# =============================================================================
# GUI SCRIPT (Media Control Solace — GTK3 + gtk-layer-shell)
# =============================================================================
write_gui_script() {
    cat > "$GUI_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
# =============================================================================
# media-control-solace - Media Control Solace GTK3 / gtk-layer-shell GUI
# Generated by mediabar-manager.sh — re-run Install to update.
#
# A thin, borderless, semi-transparent media-control bar docked to the
# bottom edge of the screen (or freely movable in float mode). Controls
# MPRIS playback (playerctl) and PipeWire volume (wpctl). Shows title/
# artist/album-art when available, with graceful fallbacks when not.
#
# See mediabar-manager.sh's "AI REFERENCE NOTES" header for the full design
# rationale (why gtk-layer-shell, colour palette source, scale-range
# research, dock/float mechanics, MPRIS fallback chain) before changing
# anything here.
# =============================================================================

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, Gdk, GLib, GdkPixbuf, Pango, GtkLayerShell
import hashlib
import math
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error

# ── Constants ─────────────────────────────────────────────────────────────────
BAR_WIDTH = 800
MIN_SCALE = 36
MAX_SCALE = 44   # == DEFAULT_SCALE, capped on purpose — see AI REFERENCE NOTES
DEFAULT_SCALE = 44
TWO_LINE_THRESHOLD = 64
SCALE_STEP = 4
MOVE_GRIP_SIZE = 22        # small square grip, bottom-right, float mode only
MOTION_THROTTLE_MS = 33    # ~30 updates/sec cap on float-mode drag-move work
TOUCHSCREEN_SIZE = (800, 480)  # used to pick the target monitor — see
                                # _select_target_monitor() in AI REFERENCE NOTES

CONFIG_DIR = os.path.expanduser("~/.config/media-control-solace")
CONFIG_FILE = os.path.join(CONFIG_DIR, "state.conf")
ART_CACHE_DIR = "/dev/shm/media-control-solace-art"

# Colour families — derived from cava-manager.sh's Cava Solace button CSS.
# Each family: base "bg"/"hover" RGB tuples (blended toward a light wash for
# the frosted look in build_css()), plus text/border as hex strings.
COLORS = {
    "neutral": {"bg": (0x1a, 0x25, 0x30), "hover": (0x22, 0x33, 0x4a),
                "text": "#b8d4e8", "border": "#2a4060"},
    "primary": {"bg": (0x1a, 0x3a, 0x22), "hover": (0x20, 0x48, 0x30),
                "text": "#7ad4a0", "border": "#2a6040"},
    "danger":  {"bg": (0x3a, 0x1a, 0x1a), "hover": (0x4a, 0x20, 0x20),
                "text": "#d47a7a", "border": "#602020"},
    "volume":  {"bg": (0x3a, 0x2e, 0x1a), "hover": (0x4a, 0x3a, 0x22),
                "text": "#d4ab6a", "border": "#5a4426"},
}
WASH = (0xb8, 0xd4, 0xe8)   # light blue wash blended into every button family
WASH_WEIGHT = 0.10          # how much of the wash shows through


def _blend(rgb, weight):
    r = int(rgb[0] * (1 - weight) + WASH[0] * weight)
    g = int(rgb[1] * (1 - weight) + WASH[1] * weight)
    b = int(rgb[2] * (1 - weight) + WASH[2] * weight)
    return r, g, b


def build_css(scale):
    """Regenerated and reloaded every time the scale changes (GTK3 CSS has
    no variables — the only way to change sizing live is to rebuild and
    reload the whole stylesheet)."""
    btn_h     = max(20, int(scale * 0.65))
    nav_w     = max(22, int(scale * 0.75))
    font_px   = max(9,  int(scale * 0.24))
    title_font_px = max(10, int(scale * 0.28))
    radius    = 8

    nb_r, nb_g, nb_b = _blend(COLORS["neutral"]["bg"], WASH_WEIGHT)

    rules = []
    rules.append(f"""
    window {{
        background-color: rgba(0, 0, 0, 0);
    }}
    .panel {{
        background-color: rgba(0, 0, 0, 0);
    }}
    .text-bg {{
        background-color: rgba({nb_r}, {nb_g}, {nb_b}, 0.55);
        border: 1px solid {COLORS['neutral']['border']};
        border-radius: {radius}px;
    }}
    button {{
        min-height: {btn_h}px;
        border-radius: {radius}px;
        padding: 1px 4px;
        font-size: {font_px}px;
    }}
    button.nav-btn {{
        min-width: {nav_w}px;
    }}
    label.nowplaying {{
        color: {COLORS['neutral']['text']};
        font-size: {title_font_px}px;
    }}
    """)

    for name, c in COLORS.items():
        bg_r, bg_g, bg_b = _blend(c["bg"], WASH_WEIGHT)
        hv_r, hv_g, hv_b = _blend(c["hover"], WASH_WEIGHT)
        rules.append(f"""
        button.{name} {{
            background-color: rgba({bg_r}, {bg_g}, {bg_b}, 0.55);
            color: {c['text']};
            border: 1px solid {c['border']};
        }}
        button.{name}:hover {{
            background-color: rgba({hv_r}, {hv_g}, {hv_b}, 0.70);
        }}
        """)

    return "\n".join(rules).encode("utf-8")


def load_state():
    state = {"scale": DEFAULT_SCALE, "mode": "dock"}
    try:
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                if key == "scale":
                    try:
                        state["scale"] = max(MIN_SCALE, min(MAX_SCALE, int(val)))
                    except ValueError:
                        pass
                elif key == "mode" and val in ("dock", "float"):
                    state["mode"] = val
    except FileNotFoundError:
        pass
    except OSError:
        pass
    return state


def save_state(scale, mode):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            f.write(f"scale={scale}\n")
            f.write(f"mode={mode}\n")
    except OSError:
        pass


class MoveGrip(Gtk.DrawingArea):
    """Small double-line grip glyph — the click-and-drag handle shown only
    in float mode, bottom-right corner."""

    def __init__(self):
        super().__init__()
        self.set_size_request(MOVE_GRIP_SIZE, MOVE_GRIP_SIZE)
        self.connect("draw", self._on_draw)

    def _on_draw(self, widget, cr):
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()
        cr.set_source_rgba(0.72, 0.83, 0.91, 0.55)
        cr.set_line_width(2)
        y1 = h * 0.40
        y2 = h * 0.62
        x0 = w * 0.20
        x1 = w * 0.80
        cr.move_to(x0, y1); cr.line_to(x1, y1); cr.stroke()
        cr.move_to(x0, y2); cr.line_to(x1, y2); cr.stroke()
        return False


class RoundedArt(Gtk.DrawingArea):
    """Album art drawn with a rounded-rectangle clip path to match the
    border-radius of the buttons. Falls back to a dark placeholder when
    no art is available."""

    def __init__(self, radius=8):
        super().__init__()
        self._radius = radius
        self._pixbuf = None
        self.connect("draw", self._on_draw)

    def set_pixbuf(self, pixbuf):
        self._pixbuf = pixbuf
        self.queue_draw()

    def clear(self):
        self._pixbuf = None
        self.queue_draw()

    def _on_draw(self, widget, cr):
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()
        if w <= 0 or h <= 0:
            return False
        r = min(self._radius, w // 3, h // 3)
        # Rounded rectangle clip
        cr.new_sub_path()
        cr.arc(w - r, r,     r, -math.pi / 2, 0)
        cr.arc(w - r, h - r, r, 0,             math.pi / 2)
        cr.arc(r,     h - r, r, math.pi / 2,   math.pi)
        cr.arc(r,     r,     r, math.pi,        3 * math.pi / 2)
        cr.close_path()
        cr.clip()
        if self._pixbuf is not None:
            pb_w = self._pixbuf.get_width()
            pb_h = self._pixbuf.get_height()
            sx = w / pb_w if pb_w > 0 else 1.0
            sy = h / pb_h if pb_h > 0 else 1.0
            cr.scale(sx, sy)
            Gdk.cairo_set_source_pixbuf(cr, self._pixbuf, 0, 0)
            cr.paint()
        else:
            cr.set_source_rgba(0.10, 0.12, 0.15, 0.80)
            cr.paint()
        return False


class MediaSolace:
    def __init__(self):
        if not GtkLayerShell.is_supported():
            # Defensive only — labwc supports this today. If this ever
            # fires, the compositor changed and this needs re-checking
            # before anything else here is touched.
            print("GtkLayerShell.is_supported() returned False — "
                  "compositor may not support wlr-layer-shell.")

        state = load_state()
        self.scale = state["scale"]
        self.mode = state["mode"]

        self._margin_left = 0
        self._margin_top = 0
        self._dragging_move = False
        self._drag_start = None
        self._pending_margin = None
        self._motion_timer_id = None
        self._closed = False
        self._metadata_proc = None

        self._last_status = ""
        self._last_player = ""
        self._last_title = ""
        self._last_artist = ""
        self._last_art_url = ""

        self.window = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.window.set_decorated(False)
        self.window.set_resizable(False)  # we drive resize ourselves
        self.window.set_app_paintable(True)

        screen = self.window.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None:
            self.window.set_visual(visual)

        # Pick the target output BEFORE realization — see
        # _select_target_monitor()'s docstring and the AI REFERENCE NOTES
        # for why this replaced a reactive get_monitor_at_window() lookup.
        self._target_monitor = self._select_target_monitor()

        GtkLayerShell.init_for_window(self.window)
        GtkLayerShell.set_layer(self.window, GtkLayerShell.Layer.TOP)
        GtkLayerShell.set_monitor(self.window, self._target_monitor)
        GtkLayerShell.set_keyboard_mode(self.window, GtkLayerShell.KeyboardMode.NONE)
        GtkLayerShell.set_exclusive_zone(self.window, 0)
        # Anchors are set per-mode in _initial_position / _pin_to_bottom /
        # _on_toggle_dock_float. Default to BOTTOM+LEFT for dock mode startup.
        if self.mode == "dock":
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.BOTTOM, True)
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.LEFT, True)
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.TOP, False)
        else:
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.TOP, True)
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.LEFT, True)
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.BOTTOM, False)

        self._css_provider = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(
            screen, self._css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        # Load CSS immediately — build_css() is otherwise only called inside
        # _apply_scale() (scale button presses), so without this the provider
        # starts empty and the entire bar renders grey on first launch.
        self._css_provider.load_from_data(build_css(self.scale))

        self._build_ui()
        self.window.connect("destroy", self._on_close)
        self.window.set_size_request(BAR_WIDTH, MIN_SCALE)
        self.window.resize(BAR_WIDTH, self.scale)

        self.window.show_all()
        self._refresh_grip_visibility()

        # Defer positioning until after show_all() — the layer-shell surface
        # must be realized before the compositor can honour margin changes.
        # Setting margins before show_all() meant the compositor hadn't
        # processed the window.resize yet, causing the bottom-edge cutoff.
        GLib.idle_add(self._initial_position)

        self._start_metadata_thread()

    def _initial_position(self):
        if self.mode == "dock":
            self._pin_to_bottom()
        else:
            # Float mode: TOP+LEFT anchor, positioned near bottom-centre by default
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.TOP, True)
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.LEFT, True)
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.BOTTOM, False)
            geo = self._monitor_geometry()
            self._margin_left = max(0, (geo.width - BAR_WIDTH) // 2)
            self._margin_top = max(0, geo.height - self.scale - 40)
            GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.LEFT, self._margin_left)
            GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.TOP, self._margin_top)
        return False  # do not repeat

    def _select_target_monitor(self):
        """Pick the monitor to pin this layer-shell surface to, decided
        BEFORE realization so there is no race querying which output the
        compositor assigned us to after the fact. Prefers the 800x480
        touchscreen — the always-present primary display for this project
        — and falls back to monitor 0 if that exact size isn't found
        (e.g. only the HDMI output is connected at launch time)."""
        display = Gdk.Display.get_default()
        n = display.get_n_monitors()
        for i in range(n):
            mon = display.get_monitor(i)
            geo = mon.get_geometry()
            if (geo.width, geo.height) == TOUCHSCREEN_SIZE:
                return mon
        return display.get_monitor(0)

    def _monitor_geometry(self):
        return self._target_monitor.get_geometry()

    def _pin_to_bottom(self):
        # Anchor BOTTOM so the bar sticks to the screen's bottom edge directly.
        # No monitor-height arithmetic — margin_bottom=0 means "flush to bottom."
        # TOP anchor must be OFF; having both TOP+BOTTOM would stretch height.
        GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.BOTTOM, True)
        GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.TOP, False)
        geo = self._monitor_geometry()
        self._margin_left = max(0, (geo.width - BAR_WIDTH) // 2)
        self._margin_top = 0
        GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.BOTTOM, 0)
        GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.LEFT, self._margin_left)

    # ── Move-grip drag throttling (float mode only) ─────────────────────────
    # Raw motion-notify-event fires at the input device's full polling
    # rate — far higher and far less even for a mouse than for the
    # touchscreen, which caused a real "smooth on touch, stutters on mouse"
    # report when this same mechanism was still also used for drag-to-resize
    # (removed in v1.0.5 — see AI REFERENCE NOTES). Still useful here: every
    # raw motion event would otherwise trigger a layer-shell margin IPC call.
    # Capping actual work to MOTION_THROTTLE_MS regardless of event rate
    # keeps this smooth on either input device.
    def _start_motion_throttle(self):
        if self._motion_timer_id is None:
            self._motion_timer_id = GLib.timeout_add(MOTION_THROTTLE_MS, self._motion_tick)

    def _stop_motion_throttle(self):
        if self._motion_timer_id is not None:
            GLib.source_remove(self._motion_timer_id)
            self._motion_timer_id = None

    def _motion_tick(self):
        if self._dragging_move and self._pending_margin is not None:
            left, top = self._pending_margin
            if (left, top) != (self._margin_left, self._margin_top):
                self._margin_left, self._margin_top = left, top
                GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.LEFT, left)
                GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.TOP, top)
        return True

    # ── UI construction ────────────────────────────────────────────────────
    def _build_ui(self):
        overlay_root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        overlay_root.get_style_context().add_class("panel")

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        row.set_margin_start(8)
        row.set_margin_end(8)
        row.set_margin_top(2)
        row.set_margin_bottom(2)
        overlay_root.pack_start(row, True, True, 0)

        self.window.add(overlay_root)

        # ── Album art (rounded corners) ─────────────────────────────────
        self.art_canvas = RoundedArt(radius=8)
        self.art_canvas.set_size_request(self.scale, self.scale)
        row.pack_start(self.art_canvas, False, False, 0)

        # ── Now playing text (dark rounded backdrop behind text only) ──────
        self.now_label = Gtk.Label()
        self.now_label.set_halign(Gtk.Align.START)
        self.now_label.set_valign(Gtk.Align.CENTER)
        self.now_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.now_label.get_style_context().add_class("nowplaying")
        self.now_label.set_margin_start(10)
        self.now_label.set_margin_end(10)
        self.now_label.set_hexpand(True)
        text_bg = Gtk.EventBox()
        text_bg.get_style_context().add_class("text-bg")
        text_bg.set_hexpand(True)
        text_bg.add(self.now_label)
        row.pack_start(text_bg, True, True, 4)

        # ── Transport group: prev / play / next ─────────────────────────
        transport_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        self.back_btn = self._make_button("\u25c0\u25c0", "neutral", nav=True)
        self.play_btn = self._make_button("\u25b6", "primary", nav=True)
        self.next_btn = self._make_button("\u25b6\u25b6", "neutral", nav=True)
        self.back_btn.connect("clicked", self._on_prev)
        self.play_btn.connect("clicked", self._on_play_pause)
        self.next_btn.connect("clicked", self._on_next)
        transport_box.pack_start(self.back_btn, False, False, 0)
        transport_box.pack_start(self.play_btn, False, False, 0)
        transport_box.pack_start(self.next_btn, False, False, 0)
        row.pack_start(transport_box, False, False, 0)

        # ── Volume group: vol- / mute / vol+ ────────────────────────────
        volume_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        volume_box.set_margin_start(10)
        self.vol_down_btn = self._make_button("\u0131l\u0131", "volume", nav=True)
        self.mute_btn     = self._make_button("\u25cb",          "volume", nav=True)
        self.vol_up_btn   = self._make_button("\u0131l\u0131l\u0131", "volume", nav=True)
        self.vol_down_btn.connect("clicked", self._on_vol_down)
        self.mute_btn.connect("clicked", self._on_mute)
        self.vol_up_btn.connect("clicked", self._on_vol_up)
        volume_box.pack_start(self.vol_down_btn, False, False, 0)
        volume_box.pack_start(self.mute_btn,     False, False, 0)
        volume_box.pack_start(self.vol_up_btn,   False, False, 0)
        row.pack_start(volume_box, False, False, 0)

        # ── Scale group: shrink / grow ───────────────────────────────────
        scale_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        scale_box.set_margin_start(10)
        self.scale_minus_btn = self._make_button("\u25be", "neutral", nav=True)
        self.scale_plus_btn  = self._make_button("\u25b4", "neutral", nav=True)
        self.scale_minus_btn.connect("clicked", self._on_scale_minus)
        self.scale_plus_btn.connect("clicked", self._on_scale_plus)
        scale_box.pack_start(self.scale_minus_btn, False, False, 0)
        scale_box.pack_start(self.scale_plus_btn,  False, False, 0)
        row.pack_start(scale_box, False, False, 0)

        # ── Controls group: dock/float / close ───────────────────────────
        controls_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        controls_box.set_margin_start(10)

        self.dock_float_btn = self._make_button(self._dock_float_label(), "neutral", nav=True)
        self.dock_float_btn.connect("clicked", self._on_toggle_dock_float)
        controls_box.pack_start(self.dock_float_btn, False, False, 0)

        self.close_btn = self._make_button("X", "danger", icon=True)
        self.close_btn.connect("clicked", lambda *_: self.window.destroy())
        controls_box.pack_start(self.close_btn, False, False, 0)

        row.pack_start(controls_box, False, False, 0)

        self.grip = MoveGrip()
        self.grip.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
        )
        self.grip.connect("button-press-event", self._on_grip_press)
        self.grip.connect("button-release-event", self._on_grip_release)
        self.grip.connect("motion-notify-event", self._on_grip_motion)
        row.pack_start(self.grip, False, False, 0)

        self._set_fallback_icon()
        self._set_now_playing_text("Nothing Playing", None)

    def _make_button(self, label, color_class, nav=False, icon=False):
        btn = Gtk.Button(label=label)
        ctx = btn.get_style_context()
        ctx.add_class(color_class)
        if nav:
            ctx.add_class("nav-btn")
        if icon:
            ctx.add_class("icon-btn")
        return btn

    def _dock_float_label(self):
        return "Float" if self.mode == "dock" else "Dock"

    def _refresh_grip_visibility(self):
        if self.mode == "float":
            self.grip.show()
        else:
            self.grip.hide()

    # ── Scale handling ──────────────────────────────────────────────────
    def _apply_scale(self, new_scale, force=False):
        new_scale = max(MIN_SCALE, min(MAX_SCALE, int(new_scale)))
        if new_scale == self.scale and not force:
            return
        self.scale = new_scale
        self._css_provider.load_from_data(build_css(self.scale))
        self.window.resize(BAR_WIDTH, self.scale)
        self._reload_art_pixbuf()
        self._refresh_now_playing_markup()
        if self.mode == "dock":
            self._pin_to_bottom()

    def _on_scale_minus(self, *_):
        self._apply_scale(self.scale - SCALE_STEP)
        save_state(self.scale, self.mode)

    def _on_scale_plus(self, *_):
        self._apply_scale(self.scale + SCALE_STEP)
        save_state(self.scale, self.mode)

    # ── Dock / float mode ─────────────────────────────────────────────────
    def _on_toggle_dock_float(self, *_):
        self.mode = "float" if self.mode == "dock" else "dock"
        self.dock_float_btn.set_label(self._dock_float_label())
        self._refresh_grip_visibility()
        if self.mode == "dock":
            self._pin_to_bottom()
        else:
            # Switch to TOP anchor for free-float dragging
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.BOTTOM, False)
            GtkLayerShell.set_anchor(self.window, GtkLayerShell.Edge.TOP, True)
            geo = self._monitor_geometry()
            self._margin_top = max(0, geo.height - self.scale - 40)
            GtkLayerShell.set_margin(self.window, GtkLayerShell.Edge.TOP, self._margin_top)
        save_state(self.scale, self.mode)

    # ── Float-mode move grip ──────────────────────────────────────────────
    def _on_grip_press(self, widget, event):
        if event.button != 1:
            return False
        self._drag_start = (event.x_root, event.y_root, self._margin_left, self._margin_top)
        self._dragging_move = True
        self._pending_margin = None
        self._start_motion_throttle()
        return True

    def _on_grip_motion(self, widget, event):
        if not self._dragging_move or self._drag_start is None:
            return False
        start_x, start_y, start_left, start_top = self._drag_start
        dx = int(event.x_root - start_x)
        dy = int(event.y_root - start_y)
        self._pending_margin = (max(0, start_left + dx), max(0, start_top + dy))
        return True

    def _on_grip_release(self, widget, event):
        self._dragging_move = False
        self._drag_start = None
        self._stop_motion_throttle()
        self._pending_margin = None
        save_state(self.scale, self.mode)
        return True

    # ── Playback / volume actions ─────────────────────────────────────────
    def _on_play_pause(self, *_):
        subprocess.Popen(["playerctl", "play-pause"])

    def _on_next(self, *_):
        subprocess.Popen(["playerctl", "next"])

    def _on_prev(self, *_):
        subprocess.Popen(["playerctl", "previous"])

    def _on_vol_up(self, *_):
        subprocess.Popen(["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "5%+"])

    def _on_vol_down(self, *_):
        subprocess.Popen(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"])

    def _on_mute(self, *_):
        subprocess.Popen(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])

    def _on_close(self, *_):
        if not self._closed:
            self._closed = True
            save_state(self.scale, self.mode)
            if self._metadata_proc is not None:
                try:
                    self._metadata_proc.terminate()
                except OSError:
                    pass
        Gtk.main_quit()

    # ── Now-playing text + fallback chain ─────────────────────────────────
    def _set_now_playing_text(self, primary, secondary):
        escaped_primary = GLib.markup_escape_text(primary)
        if secondary:
            escaped_secondary = GLib.markup_escape_text(secondary)
            markup = f"<b>{escaped_primary}</b>\n<small>{escaped_secondary}</small>"
        else:
            markup = escaped_primary
        self.now_label.set_markup(markup)

    def _refresh_now_playing_markup(self):
        self._render_now_playing(
            self._last_status, self._last_player, self._last_title, self._last_artist
        )

    def _render_now_playing(self, status, player, title, artist):
        two_line = self.scale >= TWO_LINE_THRESHOLD
        if title:
            if two_line:
                self._set_now_playing_text(title, artist if artist else None)
            else:
                combined = f"{artist} \u2013 {title}" if artist else title
                self._set_now_playing_text(combined, None)
        elif player:
            self._set_now_playing_text(f"{player} \u2014 {status}" if status else player, None)
        else:
            self._set_now_playing_text("Nothing Playing", None)

    # ── Album art ──────────────────────────────────────────────────────────
    def _set_fallback_icon(self):
        try:
            theme = Gtk.IconTheme.get_default()
            pixbuf = theme.load_icon("audio-x-generic-symbolic", self.scale, 0)
            self.art_canvas.set_pixbuf(pixbuf)
        except GLib.Error:
            self.art_canvas.clear()
        self.art_canvas.set_size_request(self.scale, self.scale)

    def _reload_art_pixbuf(self):
        self.art_canvas.set_size_request(self.scale, self.scale)
        self._load_art(self._last_art_url, force=True)

    def _load_art(self, art_url, force=False):
        if not art_url:
            self._set_fallback_icon()
            return
        if art_url == self._last_art_url and not force:
            return
        self._last_art_url = art_url

        if art_url.startswith("file://"):
            path = art_url[len("file://"):]
            self._render_art_from_path(path)
        elif art_url.startswith("http://") or art_url.startswith("https://"):
            threading.Thread(target=self._fetch_remote_art, args=(art_url,), daemon=True).start()
        else:
            self._set_fallback_icon()

    def _render_art_from_path(self, path):
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                path, self.scale, self.scale, False
            )
            self.art_canvas.set_pixbuf(pixbuf)
        except GLib.Error:
            self._set_fallback_icon()

    def _fetch_remote_art(self, url):
        try:
            os.makedirs(ART_CACHE_DIR, exist_ok=True)
            cache_key = hashlib.md5(url.encode("utf-8")).hexdigest()
            cache_path = os.path.join(ART_CACHE_DIR, cache_key)
            if not os.path.isfile(cache_path):
                req = urllib.request.Request(url, headers={"User-Agent": "media-control-solace"})
                with urllib.request.urlopen(req, timeout=5) as resp:
                    data = resp.read()
                with open(cache_path, "wb") as f:
                    f.write(data)
            GLib.idle_add(self._render_art_from_path, cache_path)
        except (urllib.error.URLError, OSError, TimeoutError):
            GLib.idle_add(self._set_fallback_icon)

    # ── Metadata thread (playerctl --follow) ──────────────────────────────
    def _start_metadata_thread(self):
        threading.Thread(target=self._metadata_loop, daemon=True).start()

    def _metadata_loop(self):
        fmt = "{{status}}|{{playerName}}|{{xesam:title}}|{{xesam:artist}}|{{mpris:artUrl}}"
        while not self._closed:
            try:
                proc = subprocess.Popen(
                    ["playerctl", "--follow", "metadata", "--format", fmt],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                self._metadata_proc = proc
                for line in proc.stdout:
                    if self._closed:
                        break
                    line = line.rstrip("\n")
                    parts = line.split("|", 4)
                    while len(parts) < 5:
                        parts.append("")
                    status, player, title, artist, art_url = parts
                    GLib.idle_add(self._update_now_playing, status, player, title, artist, art_url)
                proc.wait()
                self._metadata_proc = None
            except FileNotFoundError:
                # playerctl missing — surface once, then stop trying.
                GLib.idle_add(self._set_now_playing_text, "playerctl not found", None)
                return
            except Exception:
                pass
            if not self._closed:
                GLib.idle_add(self._update_now_playing, "", "", "", "", "")
                time.sleep(2)

    def _update_now_playing(self, status, player, title, artist, art_url):
        self._last_status = status
        self._last_player = player
        self._last_title = title
        self._last_artist = artist
        self._render_now_playing(status, player, title, artist)
        if status.lower() == "playing":
            self.play_btn.set_label("||")
        else:
            self.play_btn.set_label("\u25b6")
        self._load_art(art_url)
        return False

    # ── Signal handling ────────────────────────────────────────────────────
    def on_unix_signal(self, *_):
        self._on_close()
        return GLib.SOURCE_REMOVE


def main():
    # Single-instance guard — exit silently if already running.
    # The desktop icon launches the GUI directly (Exec=python3). This guard
    # is what prevents a second bar stacking on top of the first.
    import subprocess as _sp, os as _os
    try:
        out = _sp.check_output(
            ["pgrep", "-f", f"python3.*{__file__}"],
            stderr=_sp.DEVNULL, text=True
        ).split()
        other_pids = [p for p in out if p.strip() != str(_os.getpid())]
        if other_pids:
            sys.exit(0)
    except Exception:
        pass  # pgrep not found or other error — allow launch

    app = MediaSolace()
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, app.on_unix_signal)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, app.on_unix_signal)
    Gtk.main()


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$GUI_SCRIPT"
    info "GUI script written: $GUI_SCRIPT"
}

# =============================================================================
# GUI ICON
# =============================================================================
write_gui_icon() {
    cat > "$ICON_FILE" << 'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="14" fill="#0d0f12"/>
  <rect x="8"  y="8"  width="38" height="38" rx="7" fill="#7ad4a0"/>
  <rect x="54" y="8"  width="38" height="38" rx="7" fill="#d4ab6a"/>
  <rect x="8"  y="54" width="38" height="38" rx="7" fill="#d47a7a"/>
  <rect x="54" y="54" width="38" height="38" rx="7" fill="#b8d4e8"/>
  <circle cx="50" cy="50" r="9" fill="#0d0f12"/>
  <circle cx="50" cy="50" r="6" fill="#e0e0f0" opacity="0.9"/>
</svg>
SVGEOF
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    info "Icon written: $ICON_FILE"
}

# =============================================================================
# DESKTOP SHORTCUT — direct launch, same pattern as AirPlay Solace / Cava Solace
# =============================================================================
write_desktop_shortcut() {
    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Media Control Solace
GenericName=Media Control Bar
Comment=Borderless transparent MPRIS media control bar
Exec=python3 ${GUI_SCRIPT}
Icon=media-control-solace
Terminal=false
Categories=Audio;AudioVideo;Music;
Keywords=media;mpris;playerctl;volume;solace;
StartupNotify=false
EOF
    chmod 644 "$DESKTOP_FILE"
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    info "Desktop shortcut written: $DESKTOP_FILE"
}

# =============================================================================
# DEPENDENCIES
# =============================================================================
install_dependencies() {
    step "Checking dependencies"
    local MISSING_PKGS=()
    for pkg in python3-gi python3-cairo python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 \
               libgtk-layer-shell0 gir1.2-gtklayershell-0.1 playerctl; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            MISSING_PKGS+=("$pkg")
        fi
    done

    if ! command -v wpctl &>/dev/null && ! dpkg -s wireplumber &>/dev/null; then
        MISSING_PKGS+=("wireplumber")
    fi

    if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
        info "Installing missing dependencies: ${MISSING_PKGS[*]}"
        sudo apt-get update -qq || warn "apt-get update had issues but continuing..."
        sudo apt-get install -y "${MISSING_PKGS[@]}" || \
            error "apt-get install failed - see output above. Fix the issue and run Install again."
    else
        info "All dependencies already installed."
    fi
}

# =============================================================================
# INSTALL
# =============================================================================
do_install() {
    step "Checking platform"
    ARCH=$(uname -m)
    info "Architecture: $ARCH"
    [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]] && \
        warn "Designed for arm64/armhf (Pi 4). Detected $ARCH - continuing anyway."

    _rollback_begin "install"

    install_dependencies

    step "Writing Media Control Solace GUI script"
    write_gui_script
    if [[ ! -f "$GUI_SCRIPT" ]]; then
        error "Failed to write GUI script to $GUI_SCRIPT - check disk space and permissions."
    fi

    step "Writing icon and desktop shortcut"
    write_gui_icon
    write_desktop_shortcut

    _rollback_end

    echo ""
    divider
    echo -e "${BOLD}  Media Control Solace installed!${NC}"
    divider
    echo ""
    print_info "App menu / desktop icon:  Media Control Solace  (click to open, X button to close)"
    print_info "From this menu:           option 3  (open / close)"
    print_info "Default scale:            ${BOLD}44px${NC} (WCAG AAA touch target) - adjustable 36-44px"
    print_info "Default mode:             docked to the bottom edge, centred"
    echo ""
    print_info "Nothing runs at startup - on-demand only, no daemon."
    echo ""
    echo "  References:"
    echo "    playerctl:       https://github.com/altdesktop/playerctl"
    echo "    gtk-layer-shell: https://github.com/wmww/gtk-layer-shell"
    echo ""
}

# =============================================================================
# UPDATE
# =============================================================================
do_update() {
    if [[ ! -f "$GUI_SCRIPT" ]]; then
        error "Media Control Solace is not installed. Run Install first."
    fi

    _rollback_begin "update"

    step "Refreshing Media Control Solace GUI script"
    write_gui_script
    write_gui_icon
    write_desktop_shortcut

    _rollback_end

    if pgrep -f "python3.*$GUI_SCRIPT" >/dev/null 2>&1; then
        warn "Media Control Solace is currently running - close it and reopen to pick up this update."
    fi
    print_ok "Update complete. Your saved scale/dock-float preference is unchanged."
}

# =============================================================================
# UNINSTALL
# =============================================================================
do_uninstall() {
    step "Uninstalling Media Control Solace"

    if pgrep -f "python3.*$GUI_SCRIPT" >/dev/null 2>&1; then
        pkill -TERM -f "python3.*$GUI_SCRIPT" || true
        info "Stopped running Media Control Solace instance."
        sleep 1
    fi

    if [[ -f "$GUI_SCRIPT" ]]; then
        rm -f "$GUI_SCRIPT"
        info "Removed: $GUI_SCRIPT"
    fi
    if [[ -f "$DESKTOP_FILE" ]]; then
        rm -f "$DESKTOP_FILE"
        info "Removed: $DESKTOP_FILE"
    fi
    if [[ -f "$ICON_FILE" ]]; then
        rm -f "$ICON_FILE"
        info "Removed: $ICON_FILE"
    fi

    if [[ -d "$ART_CACHE_DIR" ]]; then
        rm -rf "$ART_CACHE_DIR"
        info "Removed RAM art cache: $ART_CACHE_DIR"
    fi

    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

    if [[ -d "$APP_CONFIG_DIR" ]]; then
        echo ""
        echo "  Config directory found: $APP_CONFIG_DIR"
        echo "  This contains your saved scale + dock/float preference."
        read -rp "$(echo -e "${CYAN}  Remove config directory? [y/N]: ${NC}")" RM_CONF
        if [[ "$RM_CONF" =~ ^[Yy]$ ]]; then
            rm -rf "$APP_CONFIG_DIR"
            info "Config directory removed."
        else
            info "Config kept at: $APP_CONFIG_DIR"
        fi
    fi

    if [[ -d "$STATE_DIR" ]]; then
        rm -rf "$STATE_DIR"
        info "Removed: $STATE_DIR"
    fi

    # ── Dependencies — kept on system (safe) ──────────────────────────────
    # playerctl, GTK3/PyGObject, and gtk-layer-shell are NOT removed. Other
    # software (or this project's other Solace apps) may depend on the GTK3/
    # PyGObject stack, and removing system packages via apt-get autoremove
    # can have unintended effects on Pi OS. If you want to remove them
    # manually later:
    #   sudo apt-get remove libgtk-layer-shell0 gir1.2-gtklayershell-0.1 playerctl
    # (python3-gi / gir1.2-gtk-3.0 / wireplumber are almost certainly needed
    # by other things on your system — leave those alone.)
    info "Dependencies are kept on your system (safe to leave installed)."
    info "To remove gtk-layer-shell/playerctl manually, see the comment in do_uninstall()."

    echo ""
    divider
    echo -e "${GREEN}  Media Control Solace fully uninstalled.${NC}"
    divider
    echo ""
    exit 0
}

# =============================================================================
# STATUS
# =============================================================================
media_solace_status() {
    if pgrep -f "python3.*$GUI_SCRIPT" >/dev/null 2>&1; then
        echo -e "  Status: ${GREEN}running${NC}  (tap the icon, or option 3, to close it)"
    elif [[ -f "$GUI_SCRIPT" ]]; then
        echo -e "  Status: ${CYAN}installed, not running${NC}"
    else
        echo -e "  Status: ${YELLOW}not installed${NC}"
    fi
}

# =============================================================================
# MAIN MENU
# =============================================================================
main_menu() {
    _check_partial_state

    while true; do
        echo ""
        divider
        echo -e "${BOLD}  Media Control Solace - Borderless Transparent Media Control Bar${NC}"
        echo -e "  MPRIS playback + PipeWire volume, on-demand, no daemon"
        divider
        echo ""
        media_solace_status
        echo ""
        echo -e "  ${CYAN}1)${NC}  Install"
        echo -e "  ${CYAN}2)${NC}  Update"
        echo -e "  ${CYAN}3)${NC}  Open / Close Media Control Solace"
        echo -e "  ${CYAN}4)${NC}  Uninstall"
        echo -e "  ${CYAN}5)${NC}  Exit"
        echo ""
        read -rp "$(echo -e "${CYAN}  Choose an option [1-5]: ${NC}")" CHOICE

        case "$CHOICE" in
            1) do_install ;;
            2) do_update  ;;
            3)
                if [[ ! -f "$GUI_SCRIPT" ]]; then
                    warn "Not installed. Run Install (option 1) first."
                elif pgrep -f "python3.*$GUI_SCRIPT" >/dev/null 2>&1; then
                    pkill -TERM -f "python3.*$GUI_SCRIPT" || true
                    info "Media Control Solace closed."
                else
                    nohup python3 "$GUI_SCRIPT" >/dev/null 2>&1 &
                    disown
                    info "Media Control Solace opened."
                fi
                ;;
            4) do_uninstall ;;
            5)
                echo ""
                echo "  Goodbye!"
                echo ""
                exit 0
                ;;
            *) warn "Invalid choice. Enter 1-5." ;;
        esac
    done
}

# =============================================================================
# ENTRY POINT
# =============================================================================
clear
echo ""
divider
echo -e "${BOLD}  Media Control Solace v1.2.0${NC}"
echo -e "  Borderless Transparent Media Control Bar - Manager"
echo -e "  Self-contained - generates all files on Install"
divider
main_menu
