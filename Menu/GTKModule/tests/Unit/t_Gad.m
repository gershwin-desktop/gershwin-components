/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../src/node.c"
#include "../../src/bridge.m"

/* The module side is not under test here. */
void gad_module_activate(unsigned long xid, const int *path, int len) {}
void gad_module_request(unsigned long xid) {}
GadNode *gad_module_snapshot(unsigned long xid) { return NULL; }
int gad_module_has_dynamic_menus(void) { return 0; }
GadNode *gad_module_refresh(unsigned long xid, int *changed) { *changed = 0; return NULL; }

static GadNode *Item(const char *title, int enabled, int state)
{
  GadNode *n = gad_node_new();
  n->title = strdup(title);
  n->enabled = enabled;
  n->state = state;
  return n;
}

int main(void)
{
  @autoreleasepool
    {
      START_SET("accelerators")
        GadNode *n = gad_node_new();
        gad_node_set_accel(n, 'o', GAD_GDK_CONTROL_MASK);
        PASS(strcmp(n->key, "o") == 0 && n->mods == (1UL << 20), "Ctrl+o maps to key o with the command mask");
        gad_node_free(n);

        n = gad_node_new();
        gad_node_set_accel(n, 'S', GAD_GDK_CONTROL_MASK | GAD_GDK_SHIFT_MASK);
        PASS(strcmp(n->key, "s") == 0 && n->mods == ((1UL << 20) | (1UL << 17)),
             "an upper case keyval becomes the lower case key plus the shift mask");
        gad_node_free(n);

        n = gad_node_new();
        gad_node_set_accel(n, 'q', GAD_GDK_MOD1_MASK | GAD_GDK_SUPER_MASK);
        PASS(n->mods == ((1UL << 19) | (1UL << 20)), "Mod1 is alt and Super is command");
        gad_node_free(n);

        n = gad_node_new();
        gad_node_set_accel(n, 0xffbe /* GDK_KEY_F1 */, 0);
        PASS(n->key[0] == '\0' && n->mods == 0, "non printable keyvals leave no key equivalent");
        gad_node_set_accel(n, 0, GAD_GDK_CONTROL_MASK);
        PASS(n->key[0] == '\0' && n->mods == 0, "keyval 0 means no accelerator");
        gad_node_free(n);
      END_SET("accelerators")

      START_SET("accelerator text")
        unsigned k = 0, m = 0;
        const char *de[5] = { "Strg", "Umschalt", "Alt", "Super", "Meta" };
        PASS(gad_parse_accel_label("Ctrl+O", de, &k, &m) && k == 'O' && m == GAD_GDK_CONTROL_MASK, "Ctrl+O");
        PASS(gad_parse_accel_label("Shift+Ctrl+S", de, &k, &m) && k == 'S'
             && m == (GAD_GDK_SHIFT_MASK | GAD_GDK_CONTROL_MASK), "two modifiers");
        PASS(gad_parse_accel_label("Strg+Umschalt+S", de, &k, &m) && k == 'S'
             && m == (GAD_GDK_SHIFT_MASK | GAD_GDK_CONTROL_MASK), "translated modifier names");
        PASS(gad_parse_accel_label("Ctrl++", de, &k, &m) && k == '+' && m == GAD_GDK_CONTROL_MASK, "the plus key");
        PASS(gad_parse_accel_label("Alt+F", NULL, &k, &m) && m == GAD_GDK_MOD1_MASK, "no translation table");
        PASS(gad_parse_accel_label("F1", de, &k, &m) == 0, "function keys are not handled");
        PASS(gad_parse_accel_label("Ctrl+Return", de, &k, &m) == 0, "named keys are not handled");
        PASS(gad_parse_accel_label("Foo+O", de, &k, &m) == 0, "unknown modifier");
        PASS(gad_parse_accel_label("", de, &k, &m) == 0 && gad_parse_accel_label(NULL, de, &k, &m) == 0, "no text");
      END_SET("accelerator text")

      START_SET("tree")
        GadNode *root = gad_node_new();
        GadNode *a = gad_node_new();
        GadNode *b = gad_node_new();
        GadNode *c = gad_node_new();
        gad_node_add_child(root, a);
        gad_node_add_child(root, b);
        gad_node_add_child(b, c);
        PASS(root->nchildren == 2 && b->nchildren == 1, "children are appended in order");

        int p0[] = { 1, 0 };
        PASS(gad_node_at_path(root, p0, 2) == c, "path 1,0 reaches the nested item");
        PASS(gad_node_at_path(root, NULL, 0) == root, "the empty path is the root");
        int p1[] = { 2 };
        PASS(gad_node_at_path(root, p1, 1) == NULL, "an index past the end finds nothing");
        int p2[] = { -1 };
        PASS(gad_node_at_path(root, p2, 1) == NULL, "a negative index finds nothing");
        int p3[] = { 0, 0 };
        PASS(gad_node_at_path(root, p3, 2) == NULL, "descending into a leaf finds nothing");
        gad_node_free(root);
        gad_node_free(NULL);
        PASS(1, "freeing NULL is harmless");
      END_SET("tree")
      GadNode *root = gad_node_new();
      GadNode *file = Item("File", 1, 0);
      file->has_submenu = 1;
      GadNode *open = Item("Open", 1, 0);
      gad_node_set_accel(open, 'o', GAD_GDK_CONTROL_MASK);
      GadNode *sep = gad_node_new();
      sep->separator = 1;
      GadNode *wrap = Item("Wrap", 0, 1);
      GadNode *unnamed = Item("", 1, 0);
      gad_node_add_child(file, open);
      gad_node_add_child(file, sep);
      gad_node_add_child(file, wrap);
      gad_node_add_child(file, unnamed);
      gad_node_add_child(root, file);

      START_SET("menu data for Menu.app")
        NSDictionary *d = DictionaryForNode(root, @"");
        PASS_EQUAL([d objectForKey:@"title"], @"", "the root has an empty title");
        NSArray *top = [d objectForKey:@"items"];
        PASS([top count] == 1, "one top level item");
        NSDictionary *fileDict = [top objectAtIndex:0];
        PASS_EQUAL([fileDict objectForKey:@"title"], @"File", "item title");
        NSDictionary *sub = [fileDict objectForKey:@"submenu"];
        PASS_EQUAL([sub objectForKey:@"title"], @"File", "the submenu is titled like its item");
        NSArray *items = [sub objectForKey:@"items"];
        PASS([items count] == 4, "separators and unnamed items keep their index");
        NSDictionary *o = [items objectAtIndex:0];
        PASS_EQUAL([o objectForKey:@"keyEquivalent"], @"o", "key equivalent");
        PASS_EQUAL([o objectForKey:@"keyEquivalentModifierMask"], [NSNumber numberWithUnsignedLong:1UL << 20], "modifier mask");
        PASS_EQUAL([o objectForKey:@"enabled"], [NSNumber numberWithBool:YES], "enabled");
        PASS_EQUAL([[items objectAtIndex:1] objectForKey:@"isSeparator"], [NSNumber numberWithBool:YES], "separator marker");
        PASS([[items objectAtIndex:1] objectForKey:@"title"] == nil, "separators carry nothing else");
        NSDictionary *w = [items objectAtIndex:2];
        PASS_EQUAL([w objectForKey:@"state"], [NSNumber numberWithInt:1], "check state");
        PASS_EQUAL([w objectForKey:@"enabled"], [NSNumber numberWithBool:NO], "disabled");
        PASS([o objectForKey:@"submenu"] == nil, "leaf items have no submenu");
        PASS_EQUAL([o objectForKey:@"shortcutViaMenu"], [NSNumber numberWithBool:YES], "items with a key equivalent ask Menu to handle it");
        PASS([w objectForKey:@"shortcutViaMenu"] == nil, "items without one do not");
      END_SET("menu data for Menu.app")

      START_SET("flat state list")
        NSMutableArray *flat = [NSMutableArray array];
        CollectStates(root, flat);
        NSArray *expect = [NSArray arrayWithObjects:
          [NSArray arrayWithObjects:@"File", [NSNumber numberWithBool:YES], [NSNumber numberWithInt:0], nil],
          [NSArray arrayWithObjects:@"Open", [NSNumber numberWithBool:YES], [NSNumber numberWithInt:0], nil],
          [NSArray arrayWithObjects:@"Wrap", [NSNumber numberWithBool:NO], [NSNumber numberWithInt:1], nil],
          nil];
        PASS_EQUAL(flat, expect, "depth first title/enabled/state triples without separators and unnamed items");
      END_SET("flat state list")

      gad_node_free(root);
    }
  return 0;
}
