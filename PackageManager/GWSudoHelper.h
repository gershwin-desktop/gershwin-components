/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWSudoHelper - Resolve the privilege-escalation command at runtime.
 *
 * The package backends must run the system package manager as root.  sudo's
 * location differs per platform: /usr/bin on Linux, but /usr/local/bin on the
 * BSDs (FreeBSD, OpenBSD, NextBSD).  Hardcoding /usr/bin/sudo broke every
 * backend on *BSD ("task has invalid launch path").  This helper also skips
 * sudo entirely when the process is already root.
 */

#import <Foundation/Foundation.h>

// Path to the sudo binary.  We never hardcode its install location; NSTask
// resolves a launch path without a slash via $PATH, so sudo is found wherever
// it lives (Linux: /usr/bin, BSDs: /usr/local/bin).  Returns a bare "sudo".
NSString *GWSudoPath(void);

// argv flags to pass to sudo, or an empty array when already root (run the
// package manager directly).  When non-empty, the command must be launched via
// GWSudoPath() with these flags followed by the package-manager command.
// Returns @[ @"-A", @"-E" ] when escalation is needed, else @[].
NSArray<NSString *> *GWSudoArgPrefix(void);

// Builds the launch path and full argument list for running toolPath with
// toolArgs, escalating through sudo when needed. Every backend needs this:
// when already root, GWSudoArgPrefix() is empty and toolPath IS the launch
// path, so toolPath must NOT also appear in the argument list (NSTask sets
// argv[0] to the launch path on its own) - getting this wrong makes the
// launched tool receive its own path as its first real argument (apt-get
// read that as an unknown "operation" and failed outright, and every
// pacman/pkg/pkg_add call had the identical bug). Returns the launch path;
// *outArguments is set to the full argument array to pass to NSTask.
NSString *GWSudoCommand(NSString *toolPath, NSArray<NSString *> *toolArgs,
                         NSArray<NSString *> **outArguments);
