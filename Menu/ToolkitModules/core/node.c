/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdlib.h>
#include <string.h>
#include "gad.h"

GadNode *gad_node_new(void)
{
  return calloc(1, sizeof(GadNode));
}

void gad_node_add_child(GadNode *parent, GadNode *child)
{
  GadNode **grown = realloc(parent->children,
                            sizeof(GadNode *) * (size_t)(parent->nchildren + 1));
  if (grown == NULL)
    {
      gad_node_free(child);
      return;
    }
  parent->children = grown;
  parent->children[parent->nchildren++] = child;
}

void gad_node_free(GadNode *node)
{
  if (node == NULL)
    return;
  for (int i = 0; i < node->nchildren; i++)
    gad_node_free(node->children[i]);
  free(node->children);
  if (node->widget_free)
    node->widget_free(node->widget);
  free(node->title);
  free(node);
}

#define NS_SHIFT   (1UL << 17)
#define NS_ALT     (1UL << 19)
#define NS_COMMAND (1UL << 20)

void gad_node_set_accel(GadNode *node, unsigned keyval, unsigned gdk_mods)
{
  /* GDK keyvals equal the character code in the printable Latin-1 range. */
  if (keyval < 0x20 || keyval > 0x7e)
    return;
  node->key[0] = (char)((keyval >= 'A' && keyval <= 'Z') ? keyval + 32 : keyval);
  node->key[1] = '\0';
  node->mods = 0;
  if (gdk_mods & GAD_GDK_SHIFT_MASK)   node->mods |= NS_SHIFT;
  /* Control is the primary modifier of GTK programs; on this desktop that is
     Command, as for GTK menus imported over D-Bus (GTKMenuParser). */
  if (gdk_mods & GAD_GDK_CONTROL_MASK) node->mods |= NS_COMMAND;
  if (gdk_mods & GAD_GDK_MOD1_MASK)    node->mods |= NS_ALT;
  if (gdk_mods & GAD_GDK_SUPER_MASK)   node->mods |= NS_COMMAND;
}

GadNode *gad_node_at_path(GadNode *root, const int *path, int len)
{
  GadNode *cur = root;
  for (int i = 0; cur && i < len; i++)
    cur = (path[i] >= 0 && path[i] < cur->nchildren) ? cur->children[path[i]] : NULL;
  return cur;
}

int gad_parse_accel_label(const char *text, const char *const names[5],
                          unsigned *keyval, unsigned *gdk_mods)
{
  static const char *const english[5] = { "Ctrl", "Shift", "Alt", "Super", "Meta" };
  static const unsigned masks[5] = { GAD_GDK_CONTROL_MASK, GAD_GDK_SHIFT_MASK,
                                     GAD_GDK_MOD1_MASK, GAD_GDK_SUPER_MASK,
                                     GAD_GDK_SUPER_MASK };
  unsigned mods = 0;
  const char *rest = text;

  if (text == NULL)
    return 0;
  for (;;)
    {
      const char *plus = strchr(rest, '+');
      size_t len;
      int found = 0;
      /* "Ctrl++" is Ctrl and the plus key: the key is what is left after the
         last modifier, even if it is the separator itself. */
      if (plus == NULL || plus == rest)
        break;
      len = (size_t)(plus - rest);
      for (int i = 0; i < 5 && !found; i++)
        {
          if ((strlen(english[i]) == len && strncmp(rest, english[i], len) == 0)
              || (names && names[i] && strlen(names[i]) == len
                  && strncmp(rest, names[i], len) == 0))
            {
              mods |= masks[i];
              found = 1;
            }
        }
      if (!found)
        return 0;
      rest = plus + 1;
    }
  if (strlen(rest) != 1 || (unsigned char)rest[0] < 0x20 || (unsigned char)rest[0] > 0x7e)
    return 0;
  *keyval = (unsigned char)rest[0];
  *gdk_mods = mods;
  return 1;
}

unsigned long long gad_node_signature(const GadNode *n, int with_state,
                                      unsigned long long h)
{
#define MIX(byte) (h = (h ^ (unsigned char)(byte)) * 1099511628211ULL)
  for (const char *c = n->title; c && *c; c++)
    MIX(*c);
  MIX(n->separator);
  MIX(n->has_submenu);
  for (const char *c = n->key; *c; c++)
    MIX(*c);
  MIX(n->mods);
  if (with_state)
    {
      MIX(n->enabled);
      MIX(n->state);
    }
  MIX('(');
  for (int i = 0; i < n->nchildren; i++)
    h = gad_node_signature(n->children[i], with_state, h);
  MIX(')');
#undef MIX
  return h;
}
