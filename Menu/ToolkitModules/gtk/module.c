/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* GTK module that hands the menu bar of every GTK window to Menu.app over
 * Distributed Objects.  It is built without GTK, GDK or GLib headers: the
 * module is loaded into a process that already runs GTK, so every function it
 * needs is resolved with dlsym() from the global scope.  The same binary
 * therefore serves GTK 2 and GTK 3. */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "gad.h"

typedef unsigned long GType;
typedef int gboolean;
typedef struct _GList { void *data; struct _GList *next, *prev; } GList;
typedef struct { GType type; union { long l; unsigned long ul; void *p; double d; } data[2]; } GValue;
typedef gboolean (*GSourceFunc)(void *);


#define FLUSH_DELAY_MS 100
#define SNAPSHOT_TIMEOUT_MS 250
#define MAX_DEPTH 16

static GType (*p_gtk_widget_get_type)(void);
static GType (*p_gtk_menu_bar_get_type)(void);
static GType (*p_gtk_menu_item_get_type)(void);
static GType (*p_gtk_separator_menu_item_get_type)(void);
static GType (*p_gtk_check_menu_item_get_type)(void);
static GType (*p_gtk_label_get_type)(void);
static GType (*p_gtk_bin_get_type)(void);
static GType (*p_gtk_container_get_type)(void);
static GList *(*p_gtk_container_get_children)(void *);
static void *(*p_gtk_menu_item_get_submenu)(void *);
static void (*p_gtk_menu_item_activate)(void *);
static void *(*p_gtk_bin_get_child)(void *);
static const char *(*p_gtk_label_get_text)(void *);
static gboolean (*p_gtk_check_menu_item_get_active)(void *);
static gboolean (*p_gtk_check_menu_item_get_inconsistent)(void *);
static gboolean (*p_gtk_widget_get_sensitive)(void *);
static gboolean (*p_gtk_widget_get_visible)(void *);
static void *(*p_gtk_widget_get_toplevel)(void *);
static void *(*p_gtk_widget_get_window)(void *);
static void (*p_gtk_widget_hide)(void *);
static void (*p_gtk_widget_show)(void *);
/* GTK 3.12 and later: accelerators that applications give a menu item as
   plain text, as GMenuModel items do. */
static const char *(*p_g_dpgettext2)(const char *, const char *, const char *);
static GType (*p_gtk_accel_label_get_type)(void);
static void (*p_gtk_accel_label_get_accel)(void *, unsigned *, unsigned *);
static const char *(*p_gtk_menu_item_get_accel_path)(void *);
static gboolean (*p_gtk_accel_map_lookup_entry)(const char *, void *);
static GList *(*p_gtk_widget_list_accel_closures)(void *);
static void *(*p_gtk_accel_group_from_accel_closure)(void *);
static void *(*p_gtk_accel_group_find)(void *, gboolean (*)(void *, void *, void *), void *);
static void (*p_g_signal_emit_by_name)(void *, const char *, ...);
static unsigned long (*p_gdk_x11_window_get_xid)(void *);
static unsigned long (*p_gdk_x11_drawable_get_xid)(void *);

static gboolean (*p_g_type_check_instance_is_a)(void *, GType);
static GType (*p_g_type_from_name)(const char *);
static void *(*p_g_type_class_ref)(GType);
static unsigned (*p_g_signal_lookup)(const char *, GType);
static unsigned long (*p_g_signal_add_emission_hook)(unsigned, unsigned, void *, void *, void *);
static unsigned long (*p_g_signal_connect_data)(void *, const char *, void (*)(void), void *, void *, int);
static void *(*p_g_object_get_data)(void *, const char *);
static void (*p_g_object_set_data)(void *, const char *, void *);
static unsigned (*p_g_idle_add)(GSourceFunc, void *);
static unsigned (*p_g_timeout_add)(unsigned, GSourceFunc, void *);
static void (*p_g_list_free)(GList *);

static GType t_menu_bar, t_menu_item, t_separator, t_check, t_label, t_bin, t_container, t_tearoff;

typedef struct
{
  void *menubar;
  unsigned long xid;
  int dirty;
  int dead;
  int hidden;
  int last_connected;
  int dynamic;                /* menus here that need a fill signal */
  unsigned long long sig;     /* node_signature of what Menu.app was sent */
} Entry;

static Entry **gEntries;
static int gEntryCount;

static int load_symbols(void)
{
  int missing = 0;
#define LOAD(name) do { *(void **)&p_##name = dlsym(RTLD_DEFAULT, #name); \
  if (p_##name == NULL) { fprintf(stderr, "gtk-appmenu-do: missing symbol %s\n", #name); missing = 1; } } while (0)
#define LOAD_OPTIONAL(name) (*(void **)&p_##name = dlsym(RTLD_DEFAULT, #name))
  LOAD(gtk_widget_get_type);
  LOAD(gtk_menu_bar_get_type);
  LOAD(gtk_menu_item_get_type);
  LOAD(gtk_separator_menu_item_get_type);
  LOAD(gtk_check_menu_item_get_type);
  LOAD(gtk_label_get_type);
  LOAD(gtk_bin_get_type);
  LOAD(gtk_container_get_type);
  LOAD(gtk_container_get_children);
  LOAD(gtk_menu_item_get_submenu);
  LOAD(gtk_menu_item_activate);
  LOAD(gtk_bin_get_child);
  LOAD(gtk_label_get_text);
  LOAD(gtk_check_menu_item_get_active);
  LOAD(gtk_check_menu_item_get_inconsistent);
  LOAD(gtk_widget_get_sensitive);
  LOAD(gtk_widget_get_visible);
  LOAD(gtk_widget_get_toplevel);
  LOAD(gtk_widget_get_window);
  LOAD(gtk_widget_hide);
  LOAD(gtk_widget_show);
  LOAD(g_type_check_instance_is_a);
  LOAD(g_type_from_name);
  LOAD(g_type_class_ref);
  LOAD(g_signal_lookup);
  LOAD(g_signal_add_emission_hook);
  LOAD(g_signal_connect_data);
  LOAD(g_object_get_data);
  LOAD(g_object_set_data);
  LOAD(g_idle_add);
  LOAD(g_timeout_add);
  LOAD(g_list_free);
  LOAD_OPTIONAL(g_dpgettext2);
  LOAD_OPTIONAL(gtk_accel_label_get_type);
  LOAD_OPTIONAL(gtk_accel_label_get_accel);
  LOAD_OPTIONAL(gtk_menu_item_get_accel_path);
  LOAD(gtk_accel_map_lookup_entry);
  LOAD(gtk_widget_list_accel_closures);
  LOAD(gtk_accel_group_from_accel_closure);
  LOAD(gtk_accel_group_find);
  LOAD(g_signal_emit_by_name);
  LOAD_OPTIONAL(gdk_x11_window_get_xid);
  LOAD_OPTIONAL(gdk_x11_drawable_get_xid);
  if (p_gdk_x11_window_get_xid == NULL && p_gdk_x11_drawable_get_xid == NULL)
    {
      fprintf(stderr, "gtk-appmenu-do: no GDK X11 window id function (not running on X11?)\n");
      missing = 1;
    }
  return !missing;
}

static int is_a(void *obj, GType type)
{
  return type != 0 && p_g_type_check_instance_is_a(obj, type);
}

static unsigned long window_xid(void *widget)
{
  void *top = p_gtk_widget_get_toplevel(widget);
  void *gdk = top ? p_gtk_widget_get_window(top) : NULL;
  if (gdk == NULL)
    return 0;
  return p_gdk_x11_window_get_xid ? p_gdk_x11_window_get_xid(gdk)
                                  : p_gdk_x11_drawable_get_xid(gdk);
}

/* ---- */

static void mark_dirty(Entry *e);

static void notify_cb(void *obj, void *pspec, Entry *e)
{
  /* Hovering an item flips focus and state properties all the time; only
     properties that show up in the global menu are worth a rebuild. */
  static const char *const relevant[] = { "sensitive", "visible", "active", "inconsistent",
                                          "label", "submenu", "use-underline", "accel-path", NULL };
  const char *name = *(const char **)((char *)pspec + sizeof(void *));
  (void)obj;
  for (int i = 0; relevant[i]; i++)
    if (strcmp(name, relevant[i]) == 0)
      {
        mark_dirty(e);
        return;
      }
}

static void container_cb(void *container, void *child, Entry *e)
{
  (void)container;
  (void)child;
  mark_dirty(e);
}

static void connect_once(void *obj, const char *signal, void (*cb)(void), Entry *e)
{
  char key[48];
  snprintf(key, sizeof key, "gad-%s", signal);
  if (p_g_object_get_data(obj, key) != NULL)
    return;
  p_g_object_set_data(obj, key, (void *)1);
  p_g_signal_connect_data(obj, signal, cb, e, NULL, 0);
}

/* ---- */

static void *find_label(void *widget, int depth)
{
  if (is_a(widget, t_label))
    return widget;
  if (depth == 0 || !is_a(widget, t_container))
    return NULL;
  void *found = NULL;
  GList *kids = p_gtk_container_get_children(widget);
  for (GList *k = kids; k && !found; k = k->next)
    found = find_label(k->data, depth - 1);
  p_g_list_free(kids);
  return found;
}

typedef struct { unsigned key, mods, flags; } AccelKey; /* GtkAccelKey */

static gboolean find_closure_cb(void *key, void *closure, void *wanted)
{
  (void)key;
  return closure == wanted;
}

/* An accelerator is either bound to an accel path or connected to the item as
   a closure.  GtkAccelLabel only resolves it when the menu is first opened, so
   ask the same sources it asks. */
/* The last label of an item that has several, e.g. title and shortcut side by side. */
static void *find_last_label(void *widget, int depth, void *title)
{
  void *found = NULL;
  if (is_a(widget, t_label))
    return widget == title ? NULL : widget;
  if (depth == 0 || !is_a(widget, t_container))
    return NULL;
  GList *kids = p_gtk_container_get_children(widget);
  for (GList *k = kids; k; k = k->next)
    {
      void *l = find_last_label(k->data, depth - 1, title);
      if (l)
        found = l;
    }
  p_g_list_free(kids);
  return found;
}

/* Applications that draw their shortcuts as a label of their own (GIMP) give
   neither an accelerator path nor a closure.  The text is what GTK would have
   drawn, with modifier names in the user's language. */
static void fill_key_from_label_text(GadNode *node, void *item, void *title)
{
  void *shortcut = find_last_label(is_a(item, t_bin) ? p_gtk_bin_get_child(item) : NULL, 3, title);
  const char *names[5] = { NULL, NULL, NULL, NULL, NULL };
  static const char *const msgid[5] = { "Ctrl", "Shift", "Alt", "Super", "Meta" };
  unsigned key, mods;
  if (shortcut == NULL)
    return;
  if (p_g_dpgettext2)
    for (int i = 0; i < 5; i++)
      {
        const char *tr = p_g_dpgettext2("gtk30", "keyboard label", msgid[i]);
        if (tr == msgid[i] || strcmp(tr, msgid[i]) == 0)
          tr = p_g_dpgettext2("gtk20", "keyboard label", msgid[i]);
        names[i] = tr;
      }
  if (gad_parse_accel_label(p_gtk_label_get_text(shortcut), names, &key, &mods))
    gad_node_set_accel(node, key, mods);
}

static void fill_key(GadNode *node, void *item, void *label)
{
  AccelKey found = { 0, 0, 0 };
  const char *path = p_gtk_menu_item_get_accel_path ? p_gtk_menu_item_get_accel_path(item) : NULL;
  if (path && p_gtk_accel_map_lookup_entry(path, &found) && found.key != 0)
    {
      gad_node_set_accel(node, found.key, found.mods);
      return;
    }
  GList *closures = p_gtk_widget_list_accel_closures(item);
  for (GList *c = closures; c && node->key[0] == '\0'; c = c->next)
    {
      void *group = p_gtk_accel_group_from_accel_closure(c->data);
      AccelKey *key = group ? p_gtk_accel_group_find(group, find_closure_cb, c->data) : NULL;
      if (key && key->key != 0)
        gad_node_set_accel(node, key->key, key->mods);
    }
  p_g_list_free(closures);
  if (node->key[0] == '\0' && label && p_gtk_accel_label_get_accel
      && p_gtk_accel_label_get_type && is_a(label, p_gtk_accel_label_get_type()))
    {
      unsigned key = 0, mods = 0;
      p_gtk_accel_label_get_accel(label, &key, &mods);
      if (key != 0)
        gad_node_set_accel(node, key, mods);
    }
  if (node->key[0] == '\0')
    fill_key_from_label_text(node, item, label);
}

/* Set by build_tree for the duration of one walk on the GTK main thread. */
static int gProbe;    /* fill menus that are found empty */
static int gRefresh;  /* run the fill signal again on menus that needed one */
static int gDynamic;  /* menus met that need a fill signal */
static int gDynamicTotal; /* the sum over all windows, read by other threads */

enum { MODE_SHOW = 1, MODE_SELECT, MODE_ACTIVATE };

static void fill_children(GadNode *parent, void *shell, Entry *e, int depth);

static void emit_fill_signal(void *item, void *submenu, int mode)
{
  switch (mode)
    {
    case MODE_SHOW:
      p_g_signal_emit_by_name(submenu, "show");
      break;
    case MODE_SELECT:
      p_g_signal_emit_by_name(item, "select");
      p_g_signal_emit_by_name(item, "deselect");
      break;
    case MODE_ACTIVATE:
      p_g_signal_emit_by_name(item, "activate");
      break;
    }
}

static GadNode *node_for_item(void *item, Entry *e, int depth)
{
  GadNode *node = gad_node_new();
  if (node == NULL)
    return NULL;
  node->widget = item;
  if (is_a(item, t_separator))
    {
      node->separator = 1;
      return node;
    }
  void *label = find_label(is_a(item, t_bin) ? p_gtk_bin_get_child(item) : NULL, 3);
  node->title = strdup(label ? p_gtk_label_get_text(label) : "");
  node->enabled = p_gtk_widget_get_sensitive(item);
  if (is_a(item, t_check))
    node->state = p_gtk_check_menu_item_get_inconsistent(item) ? -1
                  : (p_gtk_check_menu_item_get_active(item) ? 1 : 0);
  fill_key(node, item, label);
  if (e)
    connect_once(item, "notify", (void (*)(void))notify_cb, e);

  void *submenu = p_gtk_menu_item_get_submenu(item);
  if (submenu)
    {
      node->has_submenu = 1;
      int mode = (int)(long)p_g_object_get_data(submenu, "gad-fill-mode");
      /* A menu the application rebuilds whenever it is opened has to be asked
         again, or it keeps the contents of the first time. */
      if (mode && gRefresh)
        emit_fill_signal(item, submenu, mode);
      fill_children(node, submenu, e, depth + 1);
      /* Many applications fill a menu only when it is about to be used.  The
         signals that announce that are emitted by hand, least intrusive first:
         "show" on the menu reaches the handlers without mapping anything,
         "select" would pop the menu up, so it is undone at once, and
         "activate" on an item with a submenu only runs the handlers. */
      if (node->nchildren == 0 && gProbe && p_gtk_widget_get_sensitive(item)
          && p_g_object_get_data(submenu, "gad-probed") == NULL)
        {
          p_g_object_set_data(submenu, "gad-probed", (void *)1);
          for (mode = MODE_SHOW; mode <= MODE_ACTIVATE && node->nchildren == 0; mode++)
            {
              emit_fill_signal(item, submenu, mode);
              fill_children(node, submenu, e, depth + 1);
              if (node->nchildren)
                p_g_object_set_data(submenu, "gad-fill-mode", (void *)(long)mode);
            }
        }
      if (p_g_object_get_data(submenu, "gad-fill-mode"))
        gDynamic++;
    }
  return node;
}

static void fill_children(GadNode *parent, void *shell, Entry *e, int depth)
{
  if (depth > MAX_DEPTH)
    return;
  if (e)
    {
      connect_once(shell, "add", (void (*)(void))container_cb, e);
      connect_once(shell, "remove", (void (*)(void))container_cb, e);
    }
  GList *kids = p_gtk_container_get_children(shell);
  for (GList *k = kids; k; k = k->next)
    {
      void *item = k->data;
      if (!is_a(item, t_menu_item) || !p_gtk_widget_get_visible(item) || is_a(item, t_tearoff))
        continue;
      GadNode *child = node_for_item(item, e, depth);
      if (child)
        gad_node_add_child(parent, child);
    }
  p_g_list_free(kids);
}

enum { BUILD_PLAIN, BUILD_TRACK, BUILD_REFRESH };

static GadNode *build_tree(Entry *e, int mode)
{
  GadNode *root = gad_node_new();
  gProbe = (mode != BUILD_PLAIN);
  gRefresh = (mode == BUILD_REFRESH);
  gDynamic = 0;
  if (root && e->menubar)
    fill_children(root, e->menubar, mode == BUILD_TRACK ? e : NULL, 0);
  gProbe = gRefresh = 0;
  if (mode != BUILD_PLAIN)
    {
      __atomic_fetch_add(&gDynamicTotal, gDynamic - e->dynamic, __ATOMIC_RELAXED);
      e->dynamic = gDynamic;
    }
  return root;
}

/* ---- */

static void apply_visibility(Entry *e)
{
  int connected = gad_bridge_connected();
  if (e->dead || e->menubar == NULL)
    return;
  /* Only take the in-window menu bar away while Menu.app really shows it. */
  if (connected && !e->hidden)
    {
      p_gtk_widget_hide(e->menubar);
      e->hidden = 1;
    }
  else if (!connected && e->hidden)
    {
      p_gtk_widget_show(e->menubar);
      e->hidden = 0;
    }
}

static void push_entry(Entry *e)
{
  if (e->dead || e->menubar == NULL)
    return;
  GadNode *root = build_tree(e, BUILD_TRACK);
  if (root == NULL)
    return;
  gad_bridge_push(e->xid, root);
  e->sig = gad_node_signature(root, 0, GAD_SIGNATURE_SEED);
  gad_node_free(root);
  e->last_connected = gad_bridge_connected();
  apply_visibility(e);
}

static gboolean flush_cb(void *data)
{
  Entry *e = data;
  e->dirty = 0;
  push_entry(e);
  return 0;
}

static void mark_dirty(Entry *e)
{
  if (e->dirty || e->dead)
    return;
  e->dirty = 1;
  p_g_timeout_add(FLUSH_DELAY_MS, flush_cb, e);
}

static void destroy_cb(void *widget, Entry *e)
{
  (void)widget;
  e->dead = 1;
  e->menubar = NULL;
  gad_bridge_unregister(e->xid);
}

static void show_cb(void *widget, Entry *e)
{
  if (e->hidden && !e->dead)
    p_gtk_widget_hide(widget);
}

static Entry *entry_for_xid(unsigned long xid)
{
  Entry *only = NULL;
  int live = 0;
  for (int i = 0; i < gEntryCount; i++)
    {
      if (gEntries[i]->dead)
        continue;
      if (gEntries[i]->xid == xid)
        return gEntries[i];
      only = gEntries[i];
      live++;
    }
  /* Menu.app may name the application's window rather than ours. */
  return (live == 1) ? only : NULL;
}

static void register_menubar(void *menubar)
{
  if (p_g_object_get_data(menubar, "gad-entry") != NULL)
    return;
  unsigned long xid = window_xid(menubar);
  if (xid == 0)
    return;
  Entry *e = calloc(1, sizeof *e);
  Entry **grown = realloc(gEntries, sizeof(Entry *) * (size_t)(gEntryCount + 1));
  if (e == NULL || grown == NULL)
    {
      free(e);
      return;
    }
  gEntries = grown;
  gEntries[gEntryCount++] = e;
  e->menubar = menubar;
  e->xid = xid;
  p_g_object_set_data(menubar, "gad-entry", e);
  p_g_signal_connect_data(menubar, "destroy", (void (*)(void))destroy_cb, e, NULL, 0);
  p_g_signal_connect_data(menubar, "show", (void (*)(void))show_cb, e, NULL, 0);
  push_entry(e);
}

static gboolean map_hook(void *hint, unsigned n, const GValue *values, void *data)
{
  (void)hint;
  (void)data;
  if (n > 0 && values[0].data[0].p && is_a(values[0].data[0].p, t_menu_bar))
    register_menubar(values[0].data[0].p);
  return 1;
}

static gboolean tick_cb(void *data)
{
  (void)data;
  for (int i = 0; i < gEntryCount; i++)
    {
      Entry *e = gEntries[i];
      if (!e->dead && gad_bridge_connected() != e->last_connected)
        push_entry(e);
    }
  return 1;
}

/* ---- */

typedef struct
{
  unsigned long xid;
  int *path;
  int len;
} Activation;

static gboolean activate_idle(void *data)
{
  Activation *a = data;
  Entry *e = entry_for_xid(a->xid);
  GadNode *node = e ? build_tree(e, BUILD_PLAIN) : NULL;
  GadNode *cur = node ? gad_node_at_path(node, a->path, a->len) : NULL;
  if (cur == NULL || cur == node)
    fprintf(stderr, "gtk-appmenu-do: no menu item at the requested path for window 0x%lx\n", a->xid);
  else if (!cur->has_submenu && !cur->separator && p_gtk_widget_get_sensitive(cur->widget))
    p_gtk_menu_item_activate(cur->widget);
  gad_node_free(node);
  free(a->path);
  free(a);
  return 0;
}

void gad_module_activate(unsigned long xid, const int *path, int len)
{
  Activation *a = calloc(1, sizeof *a);
  if (a == NULL)
    return;
  a->xid = xid;
  a->len = len;
  a->path = malloc(sizeof(int) * (size_t)(len ? len : 1));
  if (a->path == NULL)
    {
      free(a);
      return;
    }
  memcpy(a->path, path, sizeof(int) * (size_t)len);
  p_g_idle_add(activate_idle, a);
}

static gboolean request_idle(void *data)
{
  unsigned long xid = (unsigned long)data;
  for (int i = 0; i < gEntryCount; i++)
    if (!gEntries[i]->dead && (xid == 0 || gEntries[i]->xid == xid))
      push_entry(gEntries[i]);
  return 0;
}

void gad_module_request(unsigned long xid)
{
  p_g_idle_add(request_idle, (void *)xid);
}

typedef struct
{
  unsigned long xid;
  int refresh;
  int changed;
} SnapshotRequest;

typedef struct
{
  GadNode *tree;
  int changed;
} SnapshotResult;

static void *snapshot_call(void *arg)
{
  SnapshotRequest *s = arg;
  SnapshotResult *r = calloc(1, sizeof *r);
  Entry *e = entry_for_xid(s->xid);
  if (r == NULL)
    return NULL;
  r->tree = e ? build_tree(e, s->refresh ? BUILD_REFRESH : BUILD_PLAIN) : NULL;
  if (r->tree && s->refresh)
    {
      unsigned long long sig = gad_node_signature(r->tree, 0, GAD_SIGNATURE_SEED);
      r->changed = (sig != e->sig);
      e->sig = sig;
    }
  return r;
}

static void snapshot_destroy(void *result)
{
  SnapshotResult *r = result;
  if (r)
    gad_node_free(r->tree);
  free(r);
}

static GadNode *run_on_main(unsigned long xid, int refresh, int *changed)
{
  SnapshotRequest s = { xid, refresh, 0 };
  SnapshotResult *r = gad_main_call(snapshot_call, &s, snapshot_destroy, SNAPSHOT_TIMEOUT_MS);
  GadNode *tree = NULL;
  if (r)
    {
      tree = r->tree;
      if (changed)
        *changed = r->changed;
      free(r);
    }
  return tree;
}

GadNode *gad_module_snapshot(unsigned long xid)
{
  return run_on_main(xid, 0, NULL);
}

int gad_module_has_dynamic_menus(void)
{
  return __atomic_load_n(&gDynamicTotal, __ATOMIC_RELAXED) != 0;
}

GadNode *gad_module_refresh(unsigned long xid, int *changed)
{
  *changed = 0;
  GadNode *tree = run_on_main(xid, 1, changed);
  if (tree && !*changed)
    {
      gad_node_free(tree);
      tree = NULL;
    }
  return tree;
}

/* ---- */

const char *g_module_check_init(void *module)
{
  (void)module;
  return NULL;
}

void gtk_module_init(int *argc, char ***argv)
{
  (void)argc;
  (void)argv;
  if (!load_symbols())
    return;

  t_menu_bar = p_gtk_menu_bar_get_type();
  t_menu_item = p_gtk_menu_item_get_type();
  t_separator = p_gtk_separator_menu_item_get_type();
  t_check = p_gtk_check_menu_item_get_type();
  t_label = p_gtk_label_get_type();
  t_bin = p_gtk_bin_get_type();
  t_container = p_gtk_container_get_type();
  /* GTK 2 only; the type is unknown (0) in GTK 3. */
  t_tearoff = p_g_type_from_name("GtkTearoffMenuItem");

  /* Signals only exist once the class is initialised. */
  p_g_type_class_ref(p_gtk_widget_get_type());
  unsigned signal_id = p_g_signal_lookup("map", p_gtk_widget_get_type());
  if (signal_id == 0)
    {
      fprintf(stderr, "gtk-appmenu-do: no map signal on GtkWidget\n");
      return;
    }
  gad_main_call_init(p_g_idle_add);
  gad_bridge_start();
  p_g_signal_add_emission_hook(signal_id, 0, (void *)map_hook, NULL, NULL);
  p_g_timeout_add(2000, tick_cb, NULL);
}
