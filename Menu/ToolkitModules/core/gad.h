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
  void *widget;       /* what activates the item; valid on the toolkit's main thread only */
  void (*widget_free)(void *widget); /* releases widget when the node is freed, or NULL */
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

/* Hash of the menu structure and key equivalents and, with with_state, of the
   enabled and checked state too.  Start with GAD_SIGNATURE_SEED. */
#define GAD_SIGNATURE_SEED 14695981039346656037ULL
unsigned long long gad_node_signature(const GadNode *node, int with_state,
                                      unsigned long long hash);

/* Runs fn(arg) on the GLib main loop of the toolkit, from any other thread, and
   waits up to timeout_ms for its result.  A result that arrives after the
   timeout is handed to destroy, so nothing leaks while the loop is busy.
   idle_add is g_idle_add, which the toolkit module resolved itself. */
void gad_main_call_init(unsigned (*idle_add)(int (*)(void *), void *));
void *gad_main_call(void *(*fn)(void *), void *arg, void (*destroy)(void *result),
                    int timeout_ms);

/* A toolkit module that finds menu bars by looking at the program on a timer
   (core/poller.c) describes the toolkit with this.  All of it runs on the main
   thread of the program. */
enum { GAD_BUILD_PLAIN, GAD_BUILD_PROBE, GAD_BUILD_REFRESH };

typedef struct GadToolkit
{
  /* Calls found(bar, window, xid, ctx) for every window that has a menu bar. */
  void (*enumerate)(void (*found)(void *bar, void *window, unsigned long xid, void *ctx),
                    void *ctx);
  /* PROBE fills menus that are empty, REFRESH asks the ones that were filled
     on use again.  *dynamic is the number of menus that need REFRESH. */
  GadNode *(*build)(void *bar, void *window, int mode, int *dynamic);
  int (*is_shown)(void *bar, void *window);
  void (*set_shown)(void *bar, void *window, int shown);
  /* Triggers the item that a node's widget pointer stands for. */
  void (*activate)(void *target);
} GadToolkit;

/* Starts the bridge and looks at the program every interval_ms. idle_add and
   timeout_add are g_idle_add and g_timeout_add of the toolkit's GLib. */
void gad_poller_start(const GadToolkit *toolkit,
                      unsigned (*idle_add)(int (*)(void *), void *),
                      unsigned (*timeout_add)(unsigned, int (*)(void *), void *),
                      unsigned interval_ms);

/* bridge.m - callable from the GTK main thread */
void gad_bridge_start(void);
int gad_bridge_connected(void);
void gad_bridge_push(unsigned long xid, const GadNode *root);
void gad_bridge_unregister(unsigned long xid);

/* the toolkit module - called from the Distributed Objects thread */
/* Menu.app became reachable: send every menu and take the in-window ones away. */
void gad_module_connected(void);
void gad_module_activate(unsigned long xid, const int *path, int len);
void gad_module_request(unsigned long xid);
/* Blocks the caller until the GTK main loop built a fresh tree; NULL on timeout. */
GadNode *gad_module_snapshot(unsigned long xid);

/* Only menus that needed a fill signal are asked again; cheap to call. */
int gad_module_has_dynamic_menus(void);
/* The menu tree if refreshing the dynamic menus changed its structure, else NULL. */
GadNode *gad_module_refresh(unsigned long xid, int *changed);

#endif
