# SPDX-License-Identifier: BSD-2-Clause
# Menu bar defined as a GMenuModel, as GtkApplication based programs do.
import sys
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gio, GLib

XML = """<interface><menu id="bar"><submenu><attribute name="label">Doc</attribute>
<section><item><attribute name="label">Export</attribute><attribute name="action">app.export</attribute></item></section>
</submenu></menu></interface>"""

class App(Gtk.Application):
    def do_startup(self):
        Gtk.Application.do_startup(self)
        act = Gio.SimpleAction.new("export", None)
        act.connect("activate", lambda *_: (print("ACTIVATED Export", flush=True), self.quit()))
        self.add_action(act)
        self.set_accels_for_action("app.export", ["<Primary>e"])
        self.set_menubar(Gtk.Builder.new_from_string(XML, -1).get_object("bar"))
        Gtk.Settings.get_default().set_property("gtk-shell-shows-menubar", False)

    def do_activate(self):
        win = Gtk.ApplicationWindow(application=self, title="gad gmenu")
        win.set_show_menubar(True)
        win.show_all()
        GLib.timeout_add_seconds(int(sys.argv[1]) if len(sys.argv) > 1 else 10, self.quit)

App().run([])
