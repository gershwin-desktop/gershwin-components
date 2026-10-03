/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef GAD_H
#define GAD_H

/* Plain-C description of one menu item.  It is the only thing that crosses
 * between the GTK side (module.c, no GTK headers, everything resolved with
 * dlsym) and the Distributed Objects side (bridge.m, Foundation only). */
typedef struct GadNode {
  char *title;
  int separator;
  int enabled;
  int state;          /* NSOffState 0, NSOnState 1, NSMixedState -1 */
  int has_submenu;
  char key[8];        /* UTF-8, empty when there is no key equivalent */
  unsigned long mods; /* NSEvent modifier mask */
  void *widget;       /* GtkMenuItem; valid on the GTK main thread only */
  struct GadNode **children;
  int nchildren;
} GadNode;

GadNode *gad_node_new(void);
void gad_node_add_child(GadNode *parent, GadNode *child);
void gad_node_free(GadNode *node);

/* Pure helpers, unit tested without GTK. */
#define GAD_GDK_SHIFT_MASK   (1u << 0)
#define GAD_GDK_CONTROL_MASK (1u << 2)
#define GAD_GDK_MOD1_MASK    (1u << 3)
#define GAD_GDK_SUPER_MASK   (1u << 26)
/* Stores a GDK accelerator as key equivalent and NSEvent modifier mask;
   keyvals that are not printable Latin-1 leave the node without one. */
void gad_node_set_accel(GadNode *node, unsigned keyval, unsigned gdk_mods);
/* Reads accelerator text as GTK draws it ("Ctrl+O", "Shift+Ctrl+S", German
   "Strg+O") for applications that put a plain label in the item instead of
   registering an accelerator.  names holds the translated modifier names in
   the order Ctrl, Shift, Alt, Super, Meta; the English ones are always
   accepted.  Returns 1 and the GDK key and modifiers for a single character
   key, 0 for anything else (F1, Return, no accelerator at all). */
int gad_parse_accel_label(const char *text, const char *const names[5],
                          unsigned *keyval, unsigned *gdk_mods);
/* Follows an index path through the children; NULL when it leaves the tree. */
GadNode *gad_node_at_path(GadNode *root, const int *path, int len);

/* bridge.m - callable from the GTK main thread */
void gad_bridge_start(void);
int gad_bridge_connected(void);
void gad_bridge_push(unsigned long xid, const GadNode *root);
void gad_bridge_unregister(unsigned long xid);

/* module.c - called from the Distributed Objects thread */
void gad_module_activate(unsigned long xid, const int *path, int len);
void gad_module_request(unsigned long xid);
/* Blocks the caller until the GTK main loop built a fresh tree; NULL on timeout. */
GadNode *gad_module_snapshot(unsigned long xid);

/* Only menus that needed a fill signal are asked again; cheap to call. */
int gad_module_has_dynamic_menus(void);
/* The menu tree if refreshing the dynamic menus changed its structure, else NULL. */
GadNode *gad_module_refresh(unsigned long xid, int *changed);

#endif
