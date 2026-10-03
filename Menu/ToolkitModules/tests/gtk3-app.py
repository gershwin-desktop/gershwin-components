# SPDX-License-Identifier: BSD-2-Clause
import sys
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib

win = Gtk.Window(title="gad test")
bar = Gtk.MenuBar()
file_item = Gtk.MenuItem.new_with_mnemonic("_File")
menu = Gtk.Menu()
group = Gtk.AccelGroup()
win.add_accel_group(group)
open_item = Gtk.MenuItem.new_with_mnemonic("_Open")
open_item.add_accelerator("activate", group, ord("o"), Gdk.ModifierType.CONTROL_MASK, Gtk.AccelFlags.VISIBLE)
def on_open(*_):
    # a popped up menu would be a second mapped toplevel
    print("MAPPED TOPLEVELS", len([w for w in Gtk.Window.list_toplevels() if w.get_mapped()]), flush=True)
    print("MENUBAR VISIBLE", bar.get_visible(), flush=True)
    print("ACTIVATED Open", flush=True)
    Gtk.main_quit()
open_item.connect("activate", on_open)
menu.append(open_item)
menu.append(Gtk.SeparatorMenuItem())
# a shortcut drawn as a label of its own, as GIMP does
own = Gtk.MenuItem()
box_ = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
box_.add(Gtk.Label(label="Own"))
box_.add(Gtk.Label(label="Ctrl+K"))
own.add(box_)
menu.append(own)
check = Gtk.CheckMenuItem.new_with_label("Wrap")
check.set_active(True)
menu.append(check)
off = Gtk.MenuItem.new_with_label("Disabled")
off.set_sensitive(False)
menu.append(off)
file_item.set_submenu(menu)
bar.append(file_item)
edit_item = Gtk.MenuItem.new_with_label("Edit")
edit_menu = Gtk.Menu()
edit_item.set_submenu(edit_menu)
bar.append(edit_item)
def fill_edit(menu):
    # filled only when shown, like many real applications do
    if not menu.get_children():
        menu.append(Gtk.MenuItem.new_with_label("Paste"))
        menu.show_all()
edit_menu.connect("show", fill_edit)
def lazy(label, signal, child):
    item = Gtk.MenuItem.new_with_label(label)
    menu = Gtk.Menu()
    item.set_submenu(menu)
    def fill(*_):
        if not menu.get_children():
            menu.append(Gtk.MenuItem.new_with_label(child))
            menu.show_all()
    item.connect(signal, fill)
    bar.append(item)
recent_count = [0]
recent_item = Gtk.MenuItem.new_with_label("Recent")
recent_menu = Gtk.Menu()
recent_item.set_submenu(recent_menu)
def refill_recent(*_):
    # rebuilt on every use, like a recent files list
    for c in recent_menu.get_children():
        recent_menu.remove(c)
    recent_count[0] += 1
    recent_menu.append(Gtk.MenuItem.new_with_label("Recent %d" % recent_count[0]))
    recent_menu.show_all()
recent_menu.connect("show", refill_recent)
bar.append(recent_item)
lazy("View", "select", "Zoom")
lazy("Tools", "activate", "Options")

box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
box.pack_start(bar, False, False, 0)
box.pack_start(Gtk.Label(label="body"), True, True, 0)
win.add(box)
win.connect("destroy", Gtk.main_quit)
win.show_all()
GLib.timeout_add_seconds(int(sys.argv[1]) if len(sys.argv) > 1 else 10, Gtk.main_quit)
Gtk.main()
