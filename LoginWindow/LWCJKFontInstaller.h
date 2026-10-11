/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* Body of "LoginWindow --install-cjk-font <locale>": downloads, verifies and
 * installs the Sarasa Gothic font for a Chinese, Japanese or Korean locale
 * unless fontconfig already covers the language. Runs as root, touches no
 * display. licensePath is the font's OFL text, installed next to it.
 * Returns the process exit status. */
int LWInstallCJKFont(NSString *locale, NSString *licensePath);
