/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Preloaded into the programs of a Gershwin session so that GTK 3 windows
 * with a header bar (gtk_window_set_titlebar, GtkDialog use-header-bar,
 * GtkBuilder "titlebar" children) get the window manager's title bar like
 * every other window, instead of drawing their own below it.
 *
 * GTK 3 is linked with -Bsymbolic, so its calls into itself cannot be
 * intercepted; builder templates and dialogs would escape a hook on
 * gtk_window_set_titlebar.  Its calls into GDK can, and every client-side
 * decorated toplevel asks GDK for "no decorations" when it is realized.  That
 * is the single point used here: the window keeps GTK's layout (the header
 * bar stays at the top of the window as an ordinary row of working widgets),
 * the window manager is told to decorate it, and a style sheet removes the
 * frame and shadow GTK would draw around it.
 *
 * No GTK, GDK or GLib headers and no link dependency: everything is resolved
 * by name in a process that already runs GTK 3.  Programs that never call
 * gdk_window_set_decorations (no GTK, GTK 4, Qt, GNUstep) never run any code
 * of this library, and GTK 2 is let through untouched.  Setuid programs never
 * load it: the run-time linker ignores LD_PRELOAD for them on every system we
 * support. */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#define EXPORT __attribute__((visibility("default")))

typedef unsigned long GType;
typedef int gboolean;

enum { GDK_DECOR_ALL = 1 };

/* Above application style sheets, which may style their own header bar as a
 * title bar, and below GTK_STYLE_PROVIDER_PRIORITY_USER so that a user's
 * gtk.css can still change it. */
#define NOCSD_STYLE_PRIORITY 700

/* Popup windows (menus, tooltips) keep their own frame and shadow: the window
 * manager does not decorate them either way. */
static const char nocsd_css[] =
    ".csd:not(.popup) > decoration, .solid-csd:not(.popup) > decoration {"
    " margin: 0; padding: 0; border-style: none; border-width: 0;"
    " border-radius: 0; box-shadow: none; }"
    ".csd:not(.popup), .solid-csd:not(.popup) { border-radius: 0; }"
    ".csd:not(.popup) .titlebar, .solid-csd:not(.popup) .titlebar {"
    " border-radius: 0; }";

/* The window manager's title bar has the close, minimize and zoom buttons;
 * an empty layout keeps header bars from adding a second set. */
static const char nocsd_decoration_layout[] = ":";

static struct {
    unsigned (*gtk_get_major_version)(void);
    GType (*gtk_window_get_type)(void);
    gboolean (*gtk_window_get_decorated)(void *window);
    void (*gdk_window_get_user_data)(void *window, void **data);
    void *(*gdk_window_get_screen)(void *window);
    gboolean (*g_type_check_instance_is_a)(void *instance, GType type);
    void *(*gtk_css_provider_new)(void);
    gboolean (*gtk_css_provider_load_from_data)(void *provider, const char *data, long length, void **error);
    void (*gtk_style_context_add_provider_for_screen)(void *screen, void *provider, unsigned priority);
    void *(*gtk_settings_get_for_screen)(void *screen);
    void (*g_object_set)(void *object, const char *first_property, ...);
    void (*g_object_unref)(void *object);
} gtk;

static void *resolve(void *handle, const char *name)
{
    void *symbol = dlsym(handle, name);

    if (symbol == NULL) {
        fprintf(stderr, "gershwin-gtk-nocsd: %s not found: %s\n", name, dlerror());
        abort();
    }
    return symbol;
}

#define RESOLVE(name) (*(void **)&gtk.name = resolve(RTLD_DEFAULT, #name))

/* gtk_get_major_version only exists from GTK 3 on, and GTK 4 has no
 * GdkWindow, so a program that reaches the hook without it runs GTK 2. */
static gboolean process_runs_gtk3(void)
{
    static int state = -1;

    if (state < 0) {
        *(void **)&gtk.gtk_get_major_version = dlsym(RTLD_DEFAULT, "gtk_get_major_version");
        state = gtk.gtk_get_major_version != NULL && gtk.gtk_get_major_version() == 3;
        if (state) {
            RESOLVE(gtk_window_get_type);
            RESOLVE(gtk_window_get_decorated);
            RESOLVE(gdk_window_get_user_data);
            RESOLVE(gdk_window_get_screen);
            RESOLVE(g_type_check_instance_is_a);
            RESOLVE(gtk_css_provider_new);
            RESOLVE(gtk_css_provider_load_from_data);
            RESOLVE(gtk_style_context_add_provider_for_screen);
            RESOLVE(gtk_settings_get_for_screen);
            RESOLVE(g_object_set);
            RESOLVE(g_object_unref);
        }
    }
    return state;
}

/* GTK asks for no decorations either because the program wants an
 * undecorated window (gtk_window_set_decorated, which GTK records before it
 * asks) or because the window draws its own title bar.  Only the second is
 * ours to change. */
static gboolean is_client_decorated_toplevel(void *gdk_window)
{
    void *widget = NULL;

    gtk.gdk_window_get_user_data(gdk_window, &widget);
    return widget != NULL
        && gtk.g_type_check_instance_is_a(widget, gtk.gtk_window_get_type())
        && gtk.gtk_window_get_decorated(widget);
}

/* Done when the first such window is realized rather than at load time,
 * because only then is GTK initialized and a screen there to attach to.  The
 * header bar and the style recompute before the window is first mapped. */
static void remove_client_side_frame(void *screen)
{
    static gboolean done;
    void *provider;

    if (done)
        return;
    done = 1;

    provider = gtk.gtk_css_provider_new();
    if (!gtk.gtk_css_provider_load_from_data(provider, nocsd_css, -1, NULL)) {
        fprintf(stderr, "gershwin-gtk-nocsd: GTK rejected the style sheet\n");
        abort();
    }
    gtk.gtk_style_context_add_provider_for_screen(screen, provider, NOCSD_STYLE_PRIORITY);
    gtk.g_object_unref(provider);

    gtk.g_object_set(gtk.gtk_settings_get_for_screen(screen),
                     "gtk-decoration-layout", nocsd_decoration_layout, (void *)NULL);
}

EXPORT void gdk_window_set_decorations(void *window, int decorations)
{
    static void (*next)(void *, int);

    if (next == NULL)
        *(void **)&next = resolve(RTLD_NEXT, "gdk_window_set_decorations");

    if (decorations == 0 && process_runs_gtk3() && is_client_decorated_toplevel(window)) {
        remove_client_side_frame(gtk.gdk_window_get_screen(window));
        decorations = GDK_DECOR_ALL;
    }
    next(window, decorations);
}
