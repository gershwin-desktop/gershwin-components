/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

typedef enum {
  GWSudoPolicyAllowed,   /* sudo lets the user run something */
  GWSudoPolicyRefused,   /* sudo says the user may not run anything */
  GWSudoPolicyUnknown    /* sudo gave no clear answer */
} GWSudoPolicyAnswer;

/* Asks sudo whether the invoking user may run anything at all, by listing
 * the user's privileges with `password`, which must already be known to be
 * right.  Whether a user may use sudo is a decision of the sudoers policy,
 * which only sudo can read and which it reveals only after authentication.
 * `sudoCommand` is the sudo to run ("sudo", found through PATH). */
GWSudoPolicyAnswer GWSudoPolicyForPassword(NSString *password, NSString *sudoCommand);
