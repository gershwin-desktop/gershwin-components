/*
 * Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class AGCatalog;
@class AGSidebarController;

/* The scope a sidebar row selects. */
typedef enum
{
  AGSidebarSectionDiscover = 0,
  AGSidebarSectionInstalled,
  AGSidebarSectionCategory
} AGSidebarSection;

/* The sidebar is a source list of scopes: a Library group holding Discover
   and Installed, followed by one row per tool category.  Selection here is
   what the window controller turns into the app list of the root page. */
@interface AGSidebarController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;

/* Rebuilds the row list from the catalog.  Category rows are hidden when the
   AGShowToolkitCategories default says so.  Keeps the selection when possible,
   otherwise falls back to Discover. */
- (void)reloadWithCatalog:(AGCatalog *)catalog
     showToolkitCategories:(BOOL)showToolkitCategories;

/* Selects a scope; returns NO when the category has no row (the caller then
   falls back to Discover). */
- (BOOL)selectSection:(AGSidebarSection)section rawCategory:(NSString *)rawCategory;

/* Row currently selected, for the window controller to restore or query. */
@property (nonatomic, readonly) AGSidebarSection selectedSection;
@property (nonatomic, readonly, copy) NSString *selectedRawCategory;

/* The view to place in the split view's left part. */
@property (nonatomic, readonly) NSView *view;

@end
