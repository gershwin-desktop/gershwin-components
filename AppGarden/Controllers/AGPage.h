/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* A page the window controller can push onto its navigation stack. The
   protocol only marks what belongs on the stack; a page says nothing
   about itself. The sidebar selection names the scope and the window
   title names the app, so the top bar carries no third copy. */
@protocol AGPage <NSObject>
@end
