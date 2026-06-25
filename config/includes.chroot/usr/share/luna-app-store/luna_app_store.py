#!/usr/bin/env python3
"""
Luna App Store
--------------
Shows ONLY games — all free, open-source, no accounts, no purchase flow.
Installing a game shells out to the narrow, whitelist-checked helper at
/usr/lib/luna-app-store/luna-install-game (via sudo, see
/etc/sudoers.d/luna-app-store) rather than touching apt directly.
"""

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gdk

import json
import subprocess
import threading
import shutil

CATALOG_PATH = "/usr/share/luna-app-store/catalog.json"
INSTALL_HELPER = "/usr/lib/luna-app-store/luna-install-game"
GENRES = ["All", "FPS", "Racing", "RPG", "Strategy", "Platformer", "Retro/Emulation"]
SORTS = ["Popular", "New", "Lightweight (<500 MB)", "Genre"]


def load_catalog():
    with open(CATALOG_PATH) as f:
        return json.load(f)["games"]


def is_installed(package: str) -> bool:
    try:
        result = subprocess.run(
            ["dpkg-query", "-W", "-f=${Status}", package],
            capture_output=True, text=True, timeout=5,
        )
        return "install ok installed" in result.stdout
    except Exception:
        return False


class GameCard(Gtk.Frame):
    def __init__(self, game: dict, on_state_change):
        super().__init__()
        self.game = game
        self.on_state_change = on_state_change
        self.set_size_request(220, 180)
        self.get_style_context().add_class("game-card")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_margin_top(10)
        box.set_margin_bottom(10)
        box.set_margin_start(10)
        box.set_margin_end(10)
        self.add(box)

        icon = Gtk.Image.new_from_icon_name("applications-games", Gtk.IconSize.DIALOG)
        box.pack_start(icon, False, False, 0)

        title = Gtk.Label(label=f"<b>{GLib.markup_escape_text(game['name'])}</b>")
        title.set_use_markup(True)
        box.pack_start(title, False, False, 0)

        genre_tag = Gtk.Label(label=game["genre"])
        genre_tag.get_style_context().add_class("dim-label")
        box.pack_start(genre_tag, False, False, 0)

        size_label = Gtk.Label(label=f"{game['size_mb']} MB")
        size_label.get_style_context().add_class("dim-label")
        box.pack_start(size_label, False, False, 0)

        self.spinner = Gtk.Spinner()
        box.pack_start(self.spinner, False, False, 0)

        self.action_btn = Gtk.Button()
        box.pack_start(self.action_btn, False, False, 0)
        self.action_btn.connect("clicked", self._on_click)

        self.refresh_state()

    def refresh_state(self):
        installed = is_installed(self.game["package"])
        self.spinner.stop()
        self.spinner.hide()
        if installed:
            self.action_btn.set_label("Launch")
        else:
            self.action_btn.set_label("Install")
        self.action_btn.set_sensitive(True)

    def _on_click(self, _btn):
        if self.action_btn.get_label() == "Launch":
            self._launch()
        else:
            self._install()

    def _launch(self):
        # The package name doubles as the launch binary for every game
        # in this catalog (0ad, supertuxkart, wesnoth, etc.)
        subprocess.run(
            ["/usr/lib/luna-app-store/luna-set-wallpaper", self.game["genre"]],
            check=False,
        )
        try:
            proc = subprocess.Popen(["gamemoderun", self.game["package"]])
        except FileNotFoundError:
            proc = subprocess.Popen([self.game["package"]])

        def watch_exit():
            proc.wait()
            subprocess.run(
                ["/usr/lib/luna-app-store/luna-set-wallpaper", "default"],
                check=False,
            )

        threading.Thread(target=watch_exit, daemon=True).start()

    def _install(self):
        self.action_btn.set_sensitive(False)
        self.spinner.show()
        self.spinner.start()

        def worker():
            try:
                subprocess.run(
                    ["sudo", INSTALL_HELPER, "install", self.game["package"]],
                    check=True, capture_output=True, text=True,
                )
            except subprocess.CalledProcessError:
                pass
            GLib.idle_add(self.refresh_state)
            GLib.idle_add(self.on_state_change)

        threading.Thread(target=worker, daemon=True).start()


class LunaAppStore(Gtk.Window):
    def __init__(self):
        super().__init__(title="Luna App Store")
        self.set_default_size(900, 600)
        self.set_border_width(0)
        self.connect("destroy", Gtk.main_quit)

        self.games = load_catalog()
        self.active_genre = "All"
        self.active_sort = "Popular"

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)

        # --- Header bar: genre filter + sort ---
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        header.set_margin_top(10)
        header.set_margin_bottom(10)
        header.set_margin_start(10)
        header.set_margin_end(10)
        root.pack_start(header, False, False, 0)

        genre_combo = Gtk.ComboBoxText()
        for g in GENRES:
            genre_combo.append_text(g)
        genre_combo.set_active(0)
        genre_combo.connect("changed", self._on_genre_changed)
        header.pack_start(Gtk.Label(label="Genre:"), False, False, 0)
        header.pack_start(genre_combo, False, False, 0)

        sort_combo = Gtk.ComboBoxText()
        for s in SORTS:
            sort_combo.append_text(s)
        sort_combo.set_active(0)
        sort_combo.connect("changed", self._on_sort_changed)
        header.pack_start(Gtk.Label(label="Sort:"), False, False, 0)
        header.pack_start(sort_combo, False, False, 0)

        # --- Scrollable game grid ---
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        root.pack_start(scroller, True, True, 0)

        self.flowbox = Gtk.FlowBox()
        self.flowbox.set_valign(Gtk.Align.START)
        self.flowbox.set_max_children_per_line(5)
        self.flowbox.set_selection_mode(Gtk.SelectionMode.NONE)
        self.flowbox.set_margin_top(10)
        self.flowbox.set_margin_start(10)
        self.flowbox.set_margin_end(10)
        scroller.add(self.flowbox)

        self._rebuild_grid()

    def _on_genre_changed(self, combo):
        self.active_genre = combo.get_active_text()
        self._rebuild_grid()

    def _on_sort_changed(self, combo):
        self.active_sort = combo.get_active_text()
        self._rebuild_grid()

    def _filtered_sorted_games(self):
        games = self.games
        if self.active_genre != "All":
            games = [g for g in games if g["genre"] == self.active_genre]

        if self.active_sort == "Popular":
            games = sorted(games, key=lambda g: -g["popularity"])
        elif self.active_sort == "New":
            games = sorted(games, key=lambda g: g["added"], reverse=True)
        elif self.active_sort == "Lightweight (<500 MB)":
            games = [g for g in games if g["size_mb"] < 500]
            games = sorted(games, key=lambda g: g["size_mb"])
        elif self.active_sort == "Genre":
            games = sorted(games, key=lambda g: g["genre"])

        return games

    def _rebuild_grid(self):
        for child in self.flowbox.get_children():
            self.flowbox.remove(child)

        for game in self._filtered_sorted_games():
            card = GameCard(game, on_state_change=lambda: None)
            self.flowbox.add(card)

        self.flowbox.show_all()


def main():
    if not shutil.which("sudo"):
        print("sudo not found — install cannot proceed.")
    win = LunaAppStore()
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
