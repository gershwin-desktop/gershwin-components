/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Hands the menu bar of Qt 5 and Qt 6 widget programs to Menu.app over
 * Distributed Objects.  Built without any Qt header: the functions of the Qt
 * libraries that are already loaded are called by their C++ symbol names, and
 * the few value types they return (QString, QList, QKeySequence) are read
 * through their documented memory layout, one for Qt 5 and one for Qt 6.
 *
 * Runs on the main thread of the program, driven by the GLib main loop that
 * Qt's event dispatcher is built on, so no Qt object is touched from another
 * thread. */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gad.h"

#define TICK_MS 500
#define SNAPSHOT_TIMEOUT_MS 250
#define MAX_DEPTH 16
#define MAX_DYNAMIC 256

/* Qt::AA_DontUseNativeMenuBar, in Qt 5 and Qt 6 */
enum { ATTRIBUTE_DONT_USE_NATIVE_MENU_BAR = 6 };

/* QAction::ActionEvent: Trigger is 0, Hover 1 */
enum { ACTION_TRIGGER = 0 };

static int gQt6;

/* GLib, found in the process */
static unsigned (*p_g_idle_add)(int (*)(void *), void *);
static unsigned (*p_g_timeout_add)(unsigned, int (*)(void *), void *);

/* Qt; the sret functions take the address of their result first */
static void (*p_topLevelWidgets)(void *ret);
static const void *(*p_menuWidget)(const void *mainWindow);
static int (*p_metaInherits)(const void *meta, const void *other);
static void (*p_widgetActions)(void *ret, const void *widget);
static void (*p_actionText)(void *ret, const void *action);
static int (*p_actionIsSeparator)(const void *);
static int (*p_actionIsEnabled)(const void *);
static int (*p_actionIsCheckable)(const void *);
static int (*p_actionIsChecked)(const void *);
static int (*p_actionIsVisible)(const void *);
static void *(*p_actionMenu)(const void *);
static void (*p_actionShortcut)(void *ret, const void *action);
static void (*p_keySequenceToString)(void *ret, const void *seq, int format);
static void (*p_keySequenceDtor)(void *seq);
static void (*p_actionActivate)(void *action, int event);
static void (*p_menuAboutToShow)(void *menu);
static void (*p_widgetHide)(void *);
static void (*p_widgetShow)(void *);
static void *(*p_widgetWindow)(const void *);
static uintptr_t (*p_widgetWinId)(const void *);
static int (*p_widgetIsVisibleTo)(const void *, const void *);
static void (*p_arrayDeallocate)(void *data, long size, long align);
static void (*p_listDispose)(void *data);
static const char *(*p_qVersion)(void);
static const void *gMainWindowMeta;
static const void *gMenuBarMeta;

typedef struct
{
  void *menubar;
  void *window;
  unsigned long xid;
  int seen;
  int hidden;
  int last_connected;
  int dynamic;
  unsigned long long sig;   /* structure, key equivalents and state last sent */
  unsigned long long ssig;  /* structure and key equivalents only */
} Entry;

static Entry **gEntries;
static int gEntryCount;
static int gDynamicTotal;

/* Menus found empty and filled by aboutToShow, which need it again on use. */
static void *gProbed[MAX_DYNAMIC];
static int gProbedCount;
static void *gFilled[MAX_DYNAMIC];
static int gFilledCount;

static int gProbe, gRefresh, gDynamic;

/* ---- value types ---- */

static int ref_release(int *ref)
{
  /* -1 marks static data that is never freed */
  if (*ref == -1)
    return 0;
  return __atomic_sub_fetch(ref, 1, __ATOMIC_ACQ_REL) == 0;
}

/* The pointer and length of the UTF-16 text of a QString */
static const uint16_t *qstring_chars(const void *qs, long *len)
{
  const unsigned char *s = qs;
  void *d = *(void *const *)s;
  if (d == NULL)
    {
      *len = 0;
      return NULL;
    }
  if (gQt6)
    {
      *len = *(const long *)(s + 16);
      return *(const uint16_t *const *)(s + 8);
    }
  *len = *(const int *)((const char *)d + 4);
  return (const uint16_t *)((const char *)d + *(const long *)((const char *)d + 16));
}

static void qstring_free(void *qs)
{
  void *d = *(void **)qs;
  if (d && ref_release((int *)d))
    p_arrayDeallocate(d, 2, 8);
  *(void **)qs = NULL;
}

/* UTF-8 copy of a QString, mnemonic markers and the shortcut hint removed when asked */
static char *qstring_to_utf8(const void *qs, int as_menu_text)
{
  long n;
  const uint16_t *c = qstring_chars(qs, &n);
  char *out = malloc((size_t)n * 3 + 1);
  size_t o = 0;
  if (out == NULL)
    return NULL;
  for (long i = 0; i < n; i++)
    {
      uint32_t u = c[i];
      if (as_menu_text)
        {
          if (u == '\t')
            break;
          if (u == '&')
            {
              /* "&&" is a literal ampersand, a single one marks the mnemonic */
              if (i + 1 < n && c[i + 1] == '&')
                i++;
              else
                continue;
            }
        }
      if (u >= 0xd800 && u < 0xdc00 && i + 1 < n && c[i + 1] >= 0xdc00 && c[i + 1] < 0xe000)
        u = 0x10000 + ((u - 0xd800) << 10) + (c[++i] - 0xdc00);
      if (u < 0x80)
        out[o++] = (char)u;
      else if (u < 0x800)
        {
          out[o++] = (char)(0xc0 | (u >> 6));
          out[o++] = (char)(0x80 | (u & 0x3f));
        }
      else if (u < 0x10000)
        {
          out[o++] = (char)(0xe0 | (u >> 12));
          out[o++] = (char)(0x80 | ((u >> 6) & 0x3f));
          out[o++] = (char)(0x80 | (u & 0x3f));
        }
      else
        {
          out[o++] = (char)(0xf0 | (u >> 18));
          out[o++] = (char)(0x80 | ((u >> 12) & 0x3f));
          out[o++] = (char)(0x80 | ((u >> 6) & 0x3f));
          out[o++] = (char)(0x80 | (u & 0x3f));
        }
    }
  out[o] = '\0';
  return out;
}

/* The pointers of a QList<T*>, copied; the list itself is released */
static void **qlist_take(void *qlist, int *count)
{
  unsigned char *l = qlist;
  void *d = *(void **)l;
  void **items = NULL;
  long n = 0;
  if (d == NULL)
    {
      *count = 0;
      return NULL;
    }
  if (gQt6)
    {
      n = *(long *)(l + 16);
      items = n ? malloc(sizeof(void *) * (size_t)n) : NULL;
      if (items)
        memcpy(items, *(void **)(l + 8), sizeof(void *) * (size_t)n);
      if (ref_release((int *)d))
        p_arrayDeallocate(d, 8, 8);
    }
  else
    {
      int begin = *(int *)((char *)d + 8), end = *(int *)((char *)d + 12);
      n = end - begin;
      items = n > 0 ? malloc(sizeof(void *) * (size_t)n) : NULL;
      if (items)
        memcpy(items, (char *)d + 16 + sizeof(void *) * (size_t)begin, sizeof(void *) * (size_t)n);
      if (ref_release((int *)d))
        p_listDispose(d);
    }
  *count = items ? (int)n : 0;
  *(void **)l = NULL;
  return items;
}

/* ---- tree ---- */

static int in_set(void **set, int n, void *p)
{
  for (int i = 0; i < n; i++)
    if (set[i] == p)
      return 1;
  return 0;
}

static void fill_actions(GadNode *parent, const void *widget, int depth);

static void fill_key(GadNode *node, const void *action)
{
  unsigned char seq[16] = { 0 }, str[32] = { 0 };
  unsigned key, mods;
  char *text;
  p_actionShortcut(seq, action);
  p_keySequenceToString(str, seq, 0 /* PortableText */);
  p_keySequenceDtor(seq);
  text = qstring_to_utf8(str, 0);
  qstring_free(str);
  /* "Ctrl+S, Ctrl+X" and named keys fall out, only single keys are passed on */
  if (text && gad_parse_accel_label(text, NULL, &key, &mods))
    gad_node_set_accel(node, key, mods);
  free(text);
}

static GadNode *node_for_action(const void *action, int depth)
{
  GadNode *node = gad_node_new();
  unsigned char str[32] = { 0 };
  void *menu;
  if (node == NULL)
    return NULL;
  node->widget = (void *)action;
  if (p_actionIsSeparator(action))
    {
      node->separator = 1;
      return node;
    }
  p_actionText(str, action);
  node->title = qstring_to_utf8(str, 1);
  qstring_free(str);
  node->enabled = p_actionIsEnabled(action);
  if (p_actionIsCheckable(action))
    node->state = p_actionIsChecked(action) ? 1 : 0;
  fill_key(node, action);

  menu = p_actionMenu(action);
  if (menu)
    {
      int filled = in_set(gFilled, gFilledCount, menu);
      node->has_submenu = 1;
      /* A menu the program rebuilds when it is about to be shown has to be
         asked again, or it keeps what it had the first time. */
      if (filled && gRefresh)
        p_menuAboutToShow(menu);
      fill_actions(node, menu, depth + 1);
      if (node->nchildren == 0 && gProbe && !in_set(gProbed, gProbedCount, menu)
          && gProbedCount < MAX_DYNAMIC)
        {
          gProbed[gProbedCount++] = menu;
          p_menuAboutToShow(menu);
          fill_actions(node, menu, depth + 1);
          if (node->nchildren && gFilledCount < MAX_DYNAMIC)
            {
              gFilled[gFilledCount++] = menu;
              filled = 1;
            }
        }
      if (filled)
        gDynamic++;
    }
  return node;
}

static void fill_actions(GadNode *parent, const void *widget, int depth)
{
  unsigned char list[32] = { 0 };
  int n = 0;
  void **actions;
  if (depth > MAX_DEPTH)
    return;
  p_widgetActions(list, widget);
  actions = qlist_take(list, &n);
  for (int i = 0; i < n; i++)
    {
      GadNode *child;
      if (!p_actionIsVisible(actions[i]))
        continue;
      child = node_for_action(actions[i], depth);
      if (child)
        gad_node_add_child(parent, child);
    }
  free(actions);
}

enum { BUILD_PLAIN, BUILD_PROBE, BUILD_REFRESH };

static GadNode *build_tree(Entry *e, int mode)
{
  GadNode *root = gad_node_new();
  gProbe = (mode != BUILD_PLAIN);
  gRefresh = (mode == BUILD_REFRESH);
  gDynamic = 0;
  if (root)
    fill_actions(root, e->menubar, 0);
  gProbe = gRefresh = 0;
  if (mode != BUILD_PLAIN)
    {
      __atomic_fetch_add(&gDynamicTotal, gDynamic - e->dynamic, __ATOMIC_RELAXED);
      e->dynamic = gDynamic;
    }
  return root;
}

/* ---- entries ---- */

static void apply_visibility(Entry *e)
{
  int connected = gad_bridge_connected();
  /* Only take the in-window menu bar away while Menu.app really shows it. */
  if (connected && (!e->hidden || p_widgetIsVisibleTo(e->menubar, e->window)))
    {
      p_widgetHide(e->menubar);
      e->hidden = 1;
    }
  else if (!connected && e->hidden)
    {
      p_widgetShow(e->menubar);
      e->hidden = 0;
    }
}

static void push_entry(Entry *e)
{
  GadNode *root = build_tree(e, BUILD_PROBE);
  if (root == NULL)
    return;
  gad_bridge_push(e->xid, root);
  e->sig = gad_node_signature(root, 1, GAD_SIGNATURE_SEED);
  e->ssig = gad_node_signature(root, 0, GAD_SIGNATURE_SEED);
  gad_node_free(root);
  e->last_connected = gad_bridge_connected();
  apply_visibility(e);
}

static Entry *entry_for_xid(unsigned long xid)
{
  Entry *only = NULL;
  for (int i = 0; i < gEntryCount; i++)
    {
      if (gEntries[i]->xid == xid)
        return gEntries[i];
      only = gEntries[i];
    }
  /* Menu.app may name the application's window rather than ours. */
  return gEntryCount == 1 ? only : NULL;
}

static int is_a(const void *object, const void *meta)
{
  const void *(*metaObject)(const void *) = (*(const void *(*const *const *)(const void *))object)[0];
  return p_metaInherits(metaObject(object), meta);
}

static void drop_entry(int index)
{
  Entry *e = gEntries[index];
  gad_bridge_unregister(e->xid);
  __atomic_fetch_sub(&gDynamicTotal, e->dynamic, __ATOMIC_RELAXED);
  free(e);
  gEntries[index] = gEntries[--gEntryCount];
}

static int tick_cb(void *data)
{
  unsigned char list[32] = { 0 };
  int n = 0;
  void **windows;
  (void)data;
  for (int i = 0; i < gEntryCount; i++)
    gEntries[i]->seen = 0;

  p_topLevelWidgets(list);
  windows = qlist_take(list, &n);
  for (int i = 0; i < n; i++)
    {
      const void *w = windows[i];
      const void *bar;
      Entry *e = NULL;
      if (!p_widgetIsVisibleTo(w, NULL) || !is_a(w, gMainWindowMeta))
        continue;
      bar = p_menuWidget(w);
      if (bar == NULL || !is_a(bar, gMenuBarMeta))
        continue;
      for (int j = 0; j < gEntryCount; j++)
        if (gEntries[j]->menubar == bar)
          e = gEntries[j];
      if (e == NULL)
        {
          Entry **grown = realloc(gEntries, sizeof(Entry *) * (size_t)(gEntryCount + 1));
          if (grown == NULL)
            continue;
          gEntries = grown;
          e = calloc(1, sizeof *e);
          if (e == NULL)
            continue;
          e->menubar = (void *)bar;
          e->window = (void *)w;
          e->xid = (unsigned long)p_widgetWinId(w);
          gEntries[gEntryCount++] = e;
          e->seen = 1;
          push_entry(e);
          continue;
        }
      e->seen = 1;
      /* The program changes its menus without a signal we could listen to,
         so look again; only a change is sent. */
      {
        GadNode *root = build_tree(e, BUILD_PROBE);
        if (root)
          {
            unsigned long long sig = gad_node_signature(root, 1, GAD_SIGNATURE_SEED);
            gad_node_free(root);
            if (sig != e->sig || gad_bridge_connected() != e->last_connected)
              push_entry(e);
            else
              apply_visibility(e);
          }
      }
    }
  free(windows);
  for (int i = gEntryCount - 1; i >= 0; i--)
    if (!gEntries[i]->seen)
      drop_entry(i);
  return 1;
}

/* ---- calls from the Distributed Objects thread ---- */

typedef struct
{
  unsigned long xid;
  int *path;
  int len;
} Activation;

static int activate_idle(void *data)
{
  Activation *a = data;
  Entry *e = entry_for_xid(a->xid);
  GadNode *tree = e ? build_tree(e, BUILD_PLAIN) : NULL;
  GadNode *cur = tree ? gad_node_at_path(tree, a->path, a->len) : NULL;
  if (cur == NULL || cur == tree)
    fprintf(stderr, "qt-appmenu-do: no menu item at the requested path for window 0x%lx\n", a->xid);
  else if (!cur->has_submenu && !cur->separator && cur->enabled)
    p_actionActivate(cur->widget, ACTION_TRIGGER);
  gad_node_free(tree);
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

static int request_idle(void *data)
{
  unsigned long xid = (unsigned long)data;
  for (int i = 0; i < gEntryCount; i++)
    if (xid == 0 || gEntries[i]->xid == xid)
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
      r->changed = (sig != e->ssig);
      e->ssig = sig;
      e->sig = gad_node_signature(r->tree, 1, GAD_SIGNATURE_SEED);
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
  SnapshotRequest s = { xid, refresh };
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
  GadNode *tree;
  *changed = 0;
  tree = run_on_main(xid, 1, changed);
  if (tree && !*changed)
    {
      gad_node_free(tree);
      tree = NULL;
    }
  return tree;
}

/* ---- start ---- */

/* A program normally links the Qt libraries itself, which puts them in the
   global scope.  Programs that load them privately (language bindings) do not;
   the libraries are then looked up by name, but only if already loaded. */
static void *sym(const char *name)
{
  static const char *const libs[] = {
    "libQt6Widgets.so.6", "libQt6Gui.so.6", "libQt6Core.so.6", "libglib-2.0.so.0",
    "libQt5Widgets.so.5", "libQt5Gui.so.5", "libQt5Core.so.5", NULL };
  void *found = dlsym(RTLD_DEFAULT, name);
  for (int i = 0; !found && libs[i]; i++)
    {
      void *h = dlopen(libs[i], RTLD_LAZY | RTLD_NOLOAD);
      if (h)
        {
          found = dlsym(h, name);
          dlclose(h);
        }
    }
  return found;
}

#define QSYM(var, name) do { *(void **)&(var) = sym(name); \
  if ((var) == NULL) { missing = name; } } while (0)

/* Called once, on the main thread, while the program creates its platform theme. */
void gad_qt_start(void)
{
  static int started;
  const char *missing = NULL;
  const char *version;
  if (started)
    return;
  started = 1;

  *(void **)&p_qVersion = sym("qVersion");
  if (p_qVersion == NULL)
    return;
  version = p_qVersion();
  gQt6 = (version[0] == '6');
  if (version[0] != '5' && version[0] != '6')
    {
      fprintf(stderr, "qt-appmenu-do: Qt %s is not supported\n", version);
      return;
    }

  /* Qt would otherwise hand its menu bar to the D-Bus global menu as soon as
     a registrar is on the bus, which stalls the program when that does not
     answer.  With the native menu bar off, Qt keeps an ordinary QMenuBar, which
     is what is read here and then hidden. */
  {
    void (*setAttribute)(int, int);
    *(void **)&setAttribute = sym("_ZN16QCoreApplication12setAttributeEN2Qt20ApplicationAttributeEb");
    if (setAttribute)
      setAttribute(ATTRIBUTE_DONT_USE_NATIVE_MENU_BAR, 1);
  }

  /* A program without QtWidgets has no QMenuBar to hand over, and says nothing */
  *(void **)&p_topLevelWidgets = sym("_ZN12QApplication15topLevelWidgetsEv");
  if (p_topLevelWidgets == NULL)
    return;

  *(void **)&p_g_idle_add = sym("g_idle_add");
  *(void **)&p_g_timeout_add = sym("g_timeout_add");
  if (p_g_idle_add == NULL || p_g_timeout_add == NULL)
    {
      fprintf(stderr, "qt-appmenu-do: this Qt does not run on a GLib main loop\n");
      return;
    }

  QSYM(p_menuWidget, "_ZNK11QMainWindow10menuWidgetEv");
  QSYM(p_metaInherits, "_ZNK11QMetaObject8inheritsEPKS_");
  QSYM(p_widgetActions, "_ZNK7QWidget7actionsEv");
  QSYM(p_actionText, "_ZNK7QAction4textEv");
  QSYM(p_actionIsSeparator, "_ZNK7QAction11isSeparatorEv");
  QSYM(p_actionIsEnabled, "_ZNK7QAction9isEnabledEv");
  QSYM(p_actionIsCheckable, "_ZNK7QAction11isCheckableEv");
  QSYM(p_actionIsChecked, "_ZNK7QAction9isCheckedEv");
  QSYM(p_actionIsVisible, "_ZNK7QAction9isVisibleEv");
  QSYM(p_actionMenu, gQt6 ? "_ZNK7QAction10menuObjectEv" : "_ZNK7QAction4menuEv");
  QSYM(p_actionShortcut, "_ZNK7QAction8shortcutEv");
  QSYM(p_keySequenceToString, "_ZNK12QKeySequence8toStringENS_14SequenceFormatE");
  QSYM(p_keySequenceDtor, "_ZN12QKeySequenceD1Ev");
  QSYM(p_actionActivate, "_ZN7QAction8activateENS_11ActionEventE");
  QSYM(p_menuAboutToShow, "_ZN5QMenu11aboutToShowEv");
  QSYM(p_widgetHide, "_ZN7QWidget4hideEv");
  QSYM(p_widgetShow, "_ZN7QWidget4showEv");
  QSYM(p_widgetWindow, "_ZNK7QWidget6windowEv");
  QSYM(p_widgetWinId, "_ZNK7QWidget5winIdEv");
  QSYM(p_widgetIsVisibleTo, "_ZNK7QWidget11isVisibleToEPKS_");
  QSYM(p_arrayDeallocate, gQt6 ? "_ZN10QArrayData10deallocateEPS_xx" : "_ZN10QArrayData10deallocateEPS_mm");
  if (!gQt6)
    QSYM(p_listDispose, "_ZN9QListData7disposeEPNS_4DataE");
  gMainWindowMeta = sym("_ZN11QMainWindow16staticMetaObjectE");
  gMenuBarMeta = sym("_ZN8QMenuBar16staticMetaObjectE");
  if (gMainWindowMeta == NULL || gMenuBarMeta == NULL)
    missing = "QMainWindow/QMenuBar::staticMetaObject";
  if (missing)
    {
      fprintf(stderr, "qt-appmenu-do: Qt %s lacks %s\n", version, missing);
      return;
    }

  gad_main_call_init(p_g_idle_add);
  gad_bridge_start();
  p_g_timeout_add(TICK_MS, tick_cb, NULL);
}
