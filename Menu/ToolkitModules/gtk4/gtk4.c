/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Hands the menu bar of GTK 4 programs to Menu.app over Distributed Objects.
 *
 * GTK 4 has no modules, but every GLib program loads the GIO modules found in
 * $GIO_EXTRA_MODULES while it starts; gio-stub.c is such a module and loads this
 * library, only in a program that runs GTK 4.  Menu bars in GTK 4 are GtkPopoverMenuBar
 * widgets showing a GMenuModel, so the menus are read from the model and the
 * state from the action groups they refer to, with GLib and GIO only; nothing
 * is built against any header.
 *
 * Runs on the main thread, driven by the GLib main loop (see core/poller.c). */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gad.h"

#define TICK_MS 500
#define MAX_DEPTH 16
#define MAX_WIDGETS 4000

typedef unsigned long GType;
typedef int gboolean;

static int gDebug;
#define TRACE(...) do { if (gDebug) fprintf(stderr, "gtk4-appmenu-do: " __VA_ARGS__); } while (0)

/* GLib, GObject, GIO */
static unsigned (*p_g_idle_add)(int (*)(void *), void *);
static unsigned (*p_g_timeout_add)(unsigned, int (*)(void *), void *);
static void (*p_g_free)(void *);
static void (*p_g_strfreev)(char **);
static void *(*p_g_object_ref)(void *);
static void (*p_g_object_unref)(void *);
static int (*p_g_type_check_instance_is_a)(void *, GType);
static GType (*p_g_type_from_name)(const char *);
static unsigned (*p_g_list_model_get_n_items)(void *);
static void *(*p_g_list_model_get_item)(void *, unsigned);
static int (*p_g_menu_model_get_n_items)(void *);
static void *(*p_g_menu_model_get_item_attribute_value)(void *, int, const char *, const void *);
static void *(*p_g_menu_model_get_item_link)(void *, int, const char *);
static void *(*p_g_variant_ref)(void *);
static void (*p_g_variant_unref)(void *);
static const char *(*p_g_variant_get_string)(void *, unsigned long *);
static void *(*p_g_application_get_default)(void);
static int (*p_g_action_group_query_action)(void *, const char *, int *, const void **, const void **, void **, void **);
static int (*p_g_variant_get_boolean)(void *);
static int (*p_g_variant_is_of_type)(void *, const void *);
static int (*p_g_variant_equal)(const void *, const void *);
static char *(*p_g_action_print_detailed_name)(const char *, void *);

/* GTK 4 and GDK */
static unsigned (*p_gtk_get_major_version)(void);
static void *(*p_gtk_window_get_toplevels)(void);
static int (*p_gtk_widget_get_mapped)(void *);
static int (*p_gtk_widget_get_visible)(void *);
static void (*p_gtk_widget_set_visible)(void *, int);
static void *(*p_gtk_widget_get_first_child)(void *);
static void *(*p_gtk_widget_get_next_sibling)(void *);
static void *(*p_gtk_popover_menu_bar_get_menu_model)(void *);
static GType (*p_gtk_popover_menu_bar_get_type)(void);
static GType (*p_gtk_application_get_type)(void);
static const char *(*p_gtk_actionable_get_action_name)(void *);
static void *(*p_gtk_actionable_get_action_target_value)(void *);
static GType (*p_gtk_actionable_get_type)(void);
static int (*p_gtk_widget_get_sensitive)(void *);
static void (*p_gtk_widget_activate_action_variant)(void *, const char *, void *);
static void (*p_g_object_get)(void *, const char *, ...);
static char **(*p_gtk_application_get_accels_for_action)(void *, const char *);
static int (*p_gtk_accelerator_parse)(const char *, unsigned *, unsigned *);
static void *(*p_gtk_native_get_surface)(void *);
static unsigned long (*p_gdk_x11_surface_get_xid)(void *);
static GType (*p_gdk_x11_surface_get_type)(void);

static GType t_menu_bar, t_application, t_x11_surface, t_actionable;

/* ---- where a menu item leads ---- */

/* GTK 4 gives no way to ask for the state of an action that a widget has in
   its own scope ("win."): the program inserted the group into the window and
   only GTK sees it.  The buttons the menu bar makes from the model do know,
   because their sensitivity and check state follow the action, so those are
   read instead. */
typedef struct
{
  char *detailed;   /* "win.sort-by::name" */
  int sensitive;
  int active;
} ButtonInfo;

static ButtonInfo *gButtons;
static int gButtonCount, gButtonCapacity;

typedef struct
{
  void *window;     /* owned reference */
  char *name;       /* full action name, "win.save" */
  void *target;     /* GVariant or NULL, owned */
} ActionRef;

static void action_ref_free(void *p)
{
  ActionRef *r = p;
  if (r == NULL)
    return;
  if (r->window)
    p_g_object_unref(r->window);
  if (r->target)
    p_g_variant_unref(r->target);
  free(r->name);
  free(r);
}

static int is_a(void *object, GType type)
{
  return type != 0 && object != NULL && p_g_type_check_instance_is_a(object, type);
}

static void collect_buttons(void *widget, int depth, int *budget)
{
  GType model_button;
  if (widget == NULL || depth > 2 * MAX_DEPTH || (*budget)-- <= 0)
    return;
  model_button = p_g_type_from_name("GtkModelButton");
  if (model_button && is_a(widget, model_button) && is_a(widget, t_actionable))
    {
      const char *name = p_gtk_actionable_get_action_name(widget);
      if (name && name[0])
        {
          void *target = p_gtk_actionable_get_action_target_value(widget);
          char *detailed = p_g_action_print_detailed_name(name, target);
          int active = 0;
          if (detailed)
            {
              if (gButtonCount == gButtonCapacity)
                {
                  int capacity = gButtonCapacity ? gButtonCapacity * 2 : 64;
                  ButtonInfo *grown = realloc(gButtons, sizeof *gButtons * (size_t)capacity);
                  if (grown == NULL)
                    {
                      p_g_free(detailed);
                      return;
                    }
                  gButtons = grown;
                  gButtonCapacity = capacity;
                }
              p_g_object_get(widget, "active", &active, NULL);
              gButtons[gButtonCount].detailed = strdup(detailed);
              gButtons[gButtonCount].sensitive = p_gtk_widget_get_sensitive(widget);
              gButtons[gButtonCount].active = active;
              gButtonCount++;
              p_g_free(detailed);
            }
        }
    }
  for (void *c = p_gtk_widget_get_first_child(widget); c; c = p_gtk_widget_get_next_sibling(c))
    collect_buttons(c, depth + 1, budget);
}

static void forget_buttons(void)
{
  for (int i = 0; i < gButtonCount; i++)
    free(gButtons[i].detailed);
  gButtonCount = 0;
}

static char *string_attribute(void *model, int i, const char *name)
{
  void *v = p_g_menu_model_get_item_attribute_value(model, i, name, "s");
  char *copy = NULL;
  if (v)
    {
      const char *s = p_g_variant_get_string(v, NULL);
      copy = s ? strdup(s) : NULL;
      p_g_variant_unref(v);
    }
  return copy;
}

/* "_File" is File; "__" is a literal underscore */
static char *strip_mnemonic(const char *label)
{
  char *out = malloc(strlen(label) + 1);
  size_t o = 0;
  if (out == NULL)
    return NULL;
  for (const char *c = label; *c; c++)
    {
      if (*c == '_')
        {
          if (c[1] == '_')
            c++;
          else
            continue;
        }
      out[o++] = *c;
    }
  out[o] = '\0';
  return out;
}

static void set_accel_from_strings(GadNode *node, char **accels)
{
  unsigned key = 0, mods = 0;
  if (accels && accels[0] && p_gtk_accelerator_parse(accels[0], &key, &mods) && key != 0)
    gad_node_set_accel(node, key, mods);
}

static void fill_model(GadNode *parent, void *model, void *window, int depth);

static GadNode *node_for_item(void *model, int i, void *window, int depth)
{
  GadNode *node = gad_node_new();
  char *label = string_attribute(model, i, "label");
  char *action = string_attribute(model, i, "action");
  char *hidden_when = string_attribute(model, i, "hidden-when");
  void *target = p_g_menu_model_get_item_attribute_value(model, i, "target", NULL);
  void *submenu = p_g_menu_model_get_item_link(model, i, "submenu");
  int enabled = 1, state = 0, known = 0;
  char *detailed = NULL;

  if (node == NULL)
    goto done;
  if (label == NULL)
    {
      gad_node_free(node);
      node = NULL;
      goto done;
    }
  node->title = strip_mnemonic(label);

  if (action)
    {
      detailed = p_g_action_print_detailed_name(action, target);
      for (int b = 0; detailed && b < gButtonCount; b++)
        if (strcmp(gButtons[b].detailed, detailed) == 0)
          {
            enabled = gButtons[b].sensitive;
            state = gButtons[b].active ? 1 : 0;
            known = 1;
            break;
          }
      /* The application's own actions can be asked directly. */
      if (!known && strncmp(action, "app.", 4) == 0 && p_g_application_get_default())
        {
          const void *param_type = NULL, *state_type = NULL;
          void *hint = NULL, *st = NULL;
          int en = 1;
          known = p_g_action_group_query_action(p_g_application_get_default(), action + 4, &en,
                                                &param_type, &state_type, &hint, &st);
          if (known)
            {
              enabled = en;
              if (st && state_type && p_g_variant_is_of_type(st, "b"))
                state = p_g_variant_get_boolean(st) ? 1 : 0;
              else if (st && target && p_g_variant_equal(st, target))
                state = 1;
            }
          if (hint)
            p_g_variant_unref(hint);
          if (st)
            p_g_variant_unref(st);
        }
      if (hidden_when && ((strcmp(hidden_when, "action-missing") == 0 && !known)
                          || (strcmp(hidden_when, "action-disabled") == 0 && (!known || !enabled))))
        {
          gad_node_free(node);
          node = NULL;
          goto done;
        }
      {
        ActionRef *r = calloc(1, sizeof *r);
        if (r)
          {
            r->window = p_g_object_ref(window);
            r->name = strdup(action);
            r->target = target ? p_g_variant_ref(target) : NULL;
            node->widget = r;
            node->widget_free = action_ref_free;
          }
      }

      /* An accel attribute of the item, else what the application registered */
      {
        char *accel = string_attribute(model, i, "accel");
        if (accel)
          {
            char *list[2] = { accel, NULL };
            set_accel_from_strings(node, list);
            free(accel);
          }
      }
      if (node->key[0] == '\0' && t_application && p_gtk_application_get_accels_for_action && detailed)
        {
          void *app = p_g_application_get_default();
          if (is_a(app, t_application))
            {
              char **accels = p_gtk_application_get_accels_for_action(app, detailed);
              set_accel_from_strings(node, accels);
              if (accels)
                p_g_strfreev(accels);
            }
        }
    }
  else if (submenu == NULL)
    enabled = 0;

  node->enabled = enabled;
  node->state = state;
  if (submenu)
    {
      node->has_submenu = 1;
      fill_model(node, submenu, window, depth + 1);
    }
done:
  p_g_free(detailed);
  free(label);
  free(action);
  free(hidden_when);
  if (target)
    p_g_variant_unref(target);
  if (submenu)
    p_g_object_unref(submenu);
  return node;
}

/* Sections are groups of items between separators; they carry no title here */
static void fill_model(GadNode *parent, void *model, void *window, int depth)
{
  int n;
  if (depth > MAX_DEPTH || model == NULL)
    return;
  n = p_g_menu_model_get_n_items(model);
  for (int i = 0; i < n; i++)
    {
      void *section = p_g_menu_model_get_item_link(model, i, "section");
      if (section)
        {
          GadNode *holder = gad_node_new();
          if (holder)
            {
              fill_model(holder, section, window, depth + 1);
              if (holder->nchildren > 0)
                {
                  if (parent->nchildren > 0)
                    {
                      GadNode *sep = gad_node_new();
                      if (sep)
                        {
                          sep->separator = 1;
                          gad_node_add_child(parent, sep);
                        }
                    }
                  /* move the children across */
                  for (int c = 0; c < holder->nchildren; c++)
                    gad_node_add_child(parent, holder->children[c]);
                  holder->nchildren = 0;
                }
              gad_node_free(holder);
            }
          p_g_object_unref(section);
        }
      else
        {
          GadNode *child = node_for_item(model, i, window, depth);
          if (child)
            gad_node_add_child(parent, child);
        }
    }
}

/* ---- toolkit ---- */

static GadNode *build_menu_bar(void *bar, void *window, int mode, int *dynamic)
{
  GadNode *root = gad_node_new();
  (void)mode;
  *dynamic = 0;
  if (root)
    {
      int budget = MAX_WIDGETS;
      collect_buttons(bar, 0, &budget);
      TRACE("%d model buttons below the bar\n", gButtonCount);
      fill_model(root, p_gtk_popover_menu_bar_get_menu_model(bar), window, 0);
      forget_buttons();
    }
  return root;
}

static void *find_menu_bar(void *widget, int depth, int *budget)
{
  if (widget == NULL || depth > MAX_DEPTH || (*budget)-- <= 0)
    return NULL;
  if (is_a(widget, t_menu_bar))
    return widget;
  for (void *c = p_gtk_widget_get_first_child(widget); c; c = p_gtk_widget_get_next_sibling(c))
    {
      void *found = find_menu_bar(c, depth + 1, budget);
      if (found)
        return found;
    }
  return NULL;
}

static void enumerate_windows(void (*found)(void *, void *, unsigned long, void *), void *ctx)
{
  void *list = p_gtk_window_get_toplevels();
  unsigned n = list ? p_g_list_model_get_n_items(list) : 0;
  TRACE("%u toplevels\n", n);
  for (unsigned i = 0; i < n; i++)
    {
      void *window = p_g_list_model_get_item(list, i);
      int budget = MAX_WIDGETS;
      void *bar, *surface;
      if (window == NULL)
        continue;
      TRACE("toplevel %p mapped %d\n", window, p_gtk_widget_get_mapped(window));
      if (p_gtk_widget_get_mapped(window))
        {
          bar = find_menu_bar(window, 0, &budget);
          surface = bar ? p_gtk_native_get_surface(window) : NULL;
          TRACE("window %p bar %p surface %p\n", window, bar, surface);
          if (bar && is_a(surface, t_x11_surface))
            TRACE("menu bar of window 0x%lx\n", p_gdk_x11_surface_get_xid(surface));
          if (bar && is_a(surface, t_x11_surface))
            found(bar, window, p_gdk_x11_surface_get_xid(surface), ctx);
        }
      p_g_object_unref(window);
    }
}

static int bar_is_shown(void *bar, void *window)
{
  (void)window;
  return p_gtk_widget_get_visible(bar);
}

static void set_bar_shown(void *bar, void *window, int shown)
{
  (void)window;
  p_gtk_widget_set_visible(bar, shown);
}

static void activate_action(void *target)
{
  ActionRef *r = target;
  if (r)
    p_gtk_widget_activate_action_variant(r->window, r->name, r->target);
}

static const GadToolkit gGtk4Toolkit = {
  enumerate_windows, build_menu_bar, bar_is_shown, set_bar_shown, activate_action
};

/* ---- start ---- */

#define SYM(var, name) do { *(void **)&(var) = dlsym(RTLD_DEFAULT, name); \
  if ((var) == NULL) missing = name; } while (0)

/* Called by the GIO module stub (gio-stub.c) once it knows the program runs GTK 4. */
void gad_gtk4_start(void)
{
  static int started;
  const char *missing = NULL;
  if (started)
    return;
  started = 1;
  gDebug = getenv("GAD_DEBUG") != NULL;

  /* The module is loaded by every program that uses GIO; it is for GTK 4 only. */
  *(void **)&p_gtk_get_major_version = dlsym(RTLD_DEFAULT, "gtk_get_major_version");
  if (p_gtk_get_major_version == NULL || p_gtk_get_major_version() != 4)
    return;
  TRACE("started\n");

  SYM(p_g_idle_add, "g_idle_add");
  SYM(p_g_timeout_add, "g_timeout_add");
  SYM(p_g_free, "g_free");
  SYM(p_g_strfreev, "g_strfreev");
  SYM(p_g_object_ref, "g_object_ref");
  SYM(p_g_object_unref, "g_object_unref");
  SYM(p_g_type_check_instance_is_a, "g_type_check_instance_is_a");
  SYM(p_g_type_from_name, "g_type_from_name");
  SYM(p_g_list_model_get_n_items, "g_list_model_get_n_items");
  SYM(p_g_list_model_get_item, "g_list_model_get_item");
  SYM(p_g_menu_model_get_n_items, "g_menu_model_get_n_items");
  SYM(p_g_menu_model_get_item_attribute_value, "g_menu_model_get_item_attribute_value");
  SYM(p_g_menu_model_get_item_link, "g_menu_model_get_item_link");
  SYM(p_g_variant_ref, "g_variant_ref");
  SYM(p_g_variant_unref, "g_variant_unref");
  SYM(p_g_variant_get_string, "g_variant_get_string");
  SYM(p_g_application_get_default, "g_application_get_default");
  SYM(p_g_action_print_detailed_name, "g_action_print_detailed_name");
  SYM(p_g_action_group_query_action, "g_action_group_query_action");
  SYM(p_g_variant_get_boolean, "g_variant_get_boolean");
  SYM(p_g_variant_is_of_type, "g_variant_is_of_type");
  SYM(p_g_variant_equal, "g_variant_equal");
  SYM(p_g_object_get, "g_object_get");
  SYM(p_gtk_actionable_get_action_name, "gtk_actionable_get_action_name");
  SYM(p_gtk_actionable_get_action_target_value, "gtk_actionable_get_action_target_value");
  SYM(p_gtk_actionable_get_type, "gtk_actionable_get_type");
  SYM(p_gtk_widget_get_sensitive, "gtk_widget_get_sensitive");
  SYM(p_gtk_widget_activate_action_variant, "gtk_widget_activate_action_variant");
  SYM(p_gtk_window_get_toplevels, "gtk_window_get_toplevels");
  SYM(p_gtk_widget_get_mapped, "gtk_widget_get_mapped");
  SYM(p_gtk_widget_get_visible, "gtk_widget_get_visible");
  SYM(p_gtk_widget_set_visible, "gtk_widget_set_visible");
  SYM(p_gtk_widget_get_first_child, "gtk_widget_get_first_child");
  SYM(p_gtk_widget_get_next_sibling, "gtk_widget_get_next_sibling");
  SYM(p_gtk_popover_menu_bar_get_menu_model, "gtk_popover_menu_bar_get_menu_model");
  SYM(p_gtk_popover_menu_bar_get_type, "gtk_popover_menu_bar_get_type");
  SYM(p_gtk_application_get_type, "gtk_application_get_type");
  SYM(p_gtk_application_get_accels_for_action, "gtk_application_get_accels_for_action");
  SYM(p_gtk_accelerator_parse, "gtk_accelerator_parse");
  SYM(p_gtk_native_get_surface, "gtk_native_get_surface");
  SYM(p_gdk_x11_surface_get_xid, "gdk_x11_surface_get_xid");
  SYM(p_gdk_x11_surface_get_type, "gdk_x11_surface_get_type");
  if (missing)
    {
      fprintf(stderr, "gtk4-appmenu-do: GTK 4 lacks %s\n", missing);
      return;
    }
  t_menu_bar = p_gtk_popover_menu_bar_get_type();
  t_actionable = p_gtk_actionable_get_type();
  t_application = p_gtk_application_get_type();
  t_x11_surface = p_gdk_x11_surface_get_type();

  gad_poller_start(&gGtk4Toolkit, p_g_idle_add, p_g_timeout_add, TICK_MS);
  TRACE("running\n");
}
