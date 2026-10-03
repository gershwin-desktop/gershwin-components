/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* GTK 2 counterpart of gtk3-app.py; only built when the GTK 2 headers exist. */
#include <gtk/gtk.h>
#include <stdlib.h>

static void on_open(GtkMenuItem *item, gpointer data)
{
  (void)item;
  (void)data;
  g_print("ACTIVATED Open\n");
  gtk_main_quit();
}

static gboolean quit_later(gpointer data)
{
  (void)data;
  gtk_main_quit();
  return FALSE;
}

int main(int argc, char **argv)
{
  gtk_init(&argc, &argv);
  GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  GtkAccelGroup *group = gtk_accel_group_new();
  gtk_window_add_accel_group(GTK_WINDOW(win), group);
  GtkWidget *bar = gtk_menu_bar_new();
  GtkWidget *file = gtk_menu_item_new_with_mnemonic("_File");
  GtkWidget *menu = gtk_menu_new();
  GtkWidget *open = gtk_menu_item_new_with_mnemonic("_Open");
  gtk_widget_add_accelerator(open, "activate", group, 'o', GDK_CONTROL_MASK, GTK_ACCEL_VISIBLE);
  g_signal_connect(open, "activate", G_CALLBACK(on_open), NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), open);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  GtkWidget *wrap = gtk_check_menu_item_new_with_label("Wrap");
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(wrap), TRUE);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), wrap);
  gtk_menu_item_set_submenu(GTK_MENU_ITEM(file), menu);
  gtk_menu_shell_append(GTK_MENU_SHELL(bar), file);
  GtkWidget *box = gtk_vbox_new(FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), bar, FALSE, FALSE, 0);
  gtk_container_add(GTK_CONTAINER(win), box);
  gtk_widget_show_all(win);
  g_timeout_add_seconds(argc > 1 ? atoi(argv[1]) : 10, quit_later, NULL);
  gtk_main();
  return 0;
}
