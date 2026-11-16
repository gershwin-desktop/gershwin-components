/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Keeps Menu.app's copy of the menus of a toolkit's windows up to date by
 * looking at the program on a timer, for toolkits whose menu bars cannot be
 * watched with signals from plain C (Qt, GTK 4).  Everything but the calls
 * from the Distributed Objects thread runs on the main thread, driven by the
 * GLib main loop. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gad.h"

#define SNAPSHOT_TIMEOUT_MS 250

typedef struct
{
  void *bar;
  void *window;
  unsigned long xid;
  int seen;
  int hidden;
  int last_connected;
  int dynamic;
  unsigned long long sig;   /* structure, key equivalents and state last sent */
  unsigned long long ssig;  /* structure and key equivalents only */
} Entry;

static const GadToolkit *gTk;
static unsigned (*gIdleAdd)(int (*)(void *), void *);
static Entry **gEntries;
static int gEntryCount;
static int gDynamicTotal;

static GadNode *build(Entry *e, int mode)
{
  int dynamic = 0;
  GadNode *tree = gTk->build(e->bar, e->window, mode, &dynamic);
  if (mode != GAD_BUILD_PLAIN)
    {
      __atomic_fetch_add(&gDynamicTotal, dynamic - e->dynamic, __ATOMIC_RELAXED);
      e->dynamic = dynamic;
    }
  return tree;
}

static void apply_visibility(Entry *e)
{
  int connected = gad_bridge_connected();
  /* Only take the in-window menu bar away while Menu.app really shows it. */
  if (connected && (!e->hidden || gTk->is_shown(e->bar, e->window)))
    {
      gTk->set_shown(e->bar, e->window, 0);
      e->hidden = 1;
    }
  else if (!connected && e->hidden)
    {
      gTk->set_shown(e->bar, e->window, 1);
      e->hidden = 0;
    }
}

static void push_entry(Entry *e)
{
  GadNode *root = build(e, GAD_BUILD_PROBE);
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

static void drop_entry(int index)
{
  Entry *e = gEntries[index];
  gad_bridge_unregister(e->xid);
  __atomic_fetch_sub(&gDynamicTotal, e->dynamic, __ATOMIC_RELAXED);
  free(e);
  gEntries[index] = gEntries[--gEntryCount];
}

static void window_found(void *bar, void *window, unsigned long xid, void *ctx)
{
  Entry *e = NULL;
  (void)ctx;
  for (int j = 0; j < gEntryCount; j++)
    if (gEntries[j]->bar == bar)
      e = gEntries[j];
  if (e == NULL)
    {
      Entry **grown = realloc(gEntries, sizeof(Entry *) * (size_t)(gEntryCount + 1));
      if (grown == NULL)
        return;
      gEntries = grown;
      e = calloc(1, sizeof *e);
      if (e == NULL)
        return;
      e->bar = bar;
      e->window = window;
      e->xid = xid;
      gEntries[gEntryCount++] = e;
      e->seen = 1;
      push_entry(e);
      return;
    }
  e->seen = 1;
  /* The program changes its menus without a signal we could listen to, so
     look again; only a change is sent. */
  {
    GadNode *root = build(e, GAD_BUILD_PROBE);
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

static int tick(void *data)
{
  (void)data;
  for (int i = 0; i < gEntryCount; i++)
    gEntries[i]->seen = 0;
  gTk->enumerate(window_found, NULL);
  for (int i = gEntryCount - 1; i >= 0; i--)
    if (!gEntries[i]->seen)
      drop_entry(i);
  return 1;
}

void gad_poller_start(const GadToolkit *toolkit,
                      unsigned (*idle_add)(int (*)(void *), void *),
                      unsigned (*timeout_add)(unsigned, int (*)(void *), void *),
                      unsigned interval_ms)
{
  gTk = toolkit;
  gIdleAdd = idle_add;
  gad_main_call_init(idle_add);
  gad_bridge_start();
  timeout_add(interval_ms, tick, NULL);
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
  GadNode *tree = e ? build(e, GAD_BUILD_PLAIN) : NULL;
  GadNode *cur = tree ? gad_node_at_path(tree, a->path, a->len) : NULL;
  if (cur == NULL || cur == tree)
    fprintf(stderr, "appmenu-do: no menu item at the requested path for window 0x%lx\n", a->xid);
  else if (!cur->has_submenu && !cur->separator && cur->enabled)
    gTk->activate(cur->widget);
  if (tree)
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
  gIdleAdd(activate_idle, a);
}

static int request_idle(void *data)
{
  unsigned long xid = (unsigned long)data;
  for (int i = 0; i < gEntryCount; i++)
    if (xid == 0 || gEntries[i]->xid == xid)
      push_entry(gEntries[i]);
  return 0;
}

void gad_module_connected(void)
{
  /* Before the program is up there is nothing to send yet; the tick does it. */
  if (gIdleAdd)
    gIdleAdd(request_idle, NULL);
}

void gad_module_request(unsigned long xid)
{
  gIdleAdd(request_idle, (void *)xid);
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
  r->tree = e ? build(e, s->refresh ? GAD_BUILD_REFRESH : GAD_BUILD_PLAIN) : NULL;
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
  if (r && r->tree)
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
