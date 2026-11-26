/* t_PreflightHeaders.m - ObjectTesting coverage for the preflight's handling
   of headers that ship with gnustep-make itself (its TestFramework, e.g.
   Testing.h).  Projects whose test tools use ObjectTesting must still build
   even though no distro package provides those headers.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <AppKit/AppKit.h>
#import "Testing.h"
#import "GWBuildPreflight.h"
#import <PackageManager/GWHeaderDatabase.h>
#include "../GWBuildPreflight.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* Headers from gnustep-make's TestFramework are available on every
     machine with gnustep-make and must be treated as installed. */
  PASS([GWBuildPreflight headerIsShippedWithGnustepMake: @"Testing.h"],
       "Testing.h ships with gnustep-make");
  PASS([GWBuildPreflight headerIsShippedWithGnustepMake: @"ObjectTesting.h"],
       "ObjectTesting.h ships with gnustep-make");

  /* Anything outside the TestFramework stays unresolved so the package
     manager still gets a chance to install it. */
  PASS(![GWBuildPreflight headerIsShippedWithGnustepMake: @"curl/curl.h"],
       "curl/curl.h does not ship with gnustep-make");
  PASS(![GWBuildPreflight headerIsShippedWithGnustepMake: @"TestingX.h"],
        "unknown headers are not claimed as gnustep-make headers");

  /* Headers the stack itself ships live in /System/Library/Headers and are in
     no distro package database, so the database must find them there.  Without
     this, a project including <dispatch/dispatch.h> is told to install a
     package that does not exist.  The header is only asserted when this
     machine really has it, so the test stays honest elsewhere. */
  {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dispatch = @"/System/Library/Headers/dispatch/dispatch.h";
    if (![fm fileExistsAtPath: dispatch]) {
      PASS(YES, "no /System/Library/Headers; skipped dispatch/dispatch.h case");
    } else {
      GWHeaderDatabase *db = [GWHeaderDatabase sharedDatabase];
      if (![db isOpen]) {
        PASS(YES, "headers.db not readable; skipped dispatch/dispatch.h case");
      } else {
        NSString *distro = [db databaseDistroForCurrentOS];
        BOOL found = [db isHeaderInstalled: @"dispatch/dispatch.h" distro: distro];
        BOOL absent = ![db isHeaderInstalled: @"NoSuchHeaderXYZ.h" distro: distro];
        PASS(found, "dispatch/dispatch.h resolves from /System/Library/Headers");
        PASS(absent, "a genuinely absent header is still reported as missing");
      }
    }
  }

  /* A header guarded by a foreign-OS macro that is never defined on this host
     (e.g. windows.h under #ifdef __MINGW32__) is dead code and must be
     skipped, not reported as a missing dependency. */
  {
    GWBuildPreflight *pf = [GWBuildPreflight new];
    NSString *src = @"#ifdef __MINGW32__\n#include <windows.h>\n#endif\n";
    NSMutableDictionary *macros = [pf _macroEnvironment];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src macros:macros lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 1, "windows.h is matched");
    PASS([pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                             actives:actives inBlocks:inBlocks ranges:ranges],
         "windows.h under __MINGW32__ is skipped");
    [pf release];
  }

  /* A commented-out import is dead code and must be skipped. */
  {
    GWBuildPreflight *pf = [GWBuildPreflight new];
    NSString *src = @"//#import <Renaissance/Renaissance.h>\n";
    NSMutableDictionary *macros = [pf _macroEnvironment];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src macros:macros lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 1, "commented Renaissance import is matched");
    PASS([pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                             actives:actives inBlocks:inBlocks ranges:ranges],
         "commented-out import is skipped");
    [pf release];
  }

  /* A header that is actually compiled must NOT be skipped. */
  {
    GWBuildPreflight *pf = [GWBuildPreflight new];
    NSString *src = @"#import <stdio.h>\n";
    NSMutableDictionary *macros = [pf _macroEnvironment];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src macros:macros lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 1, "stdio.h is matched");
    PASS(![pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                              actives:actives inBlocks:inBlocks ranges:ranges],
         "compiled import is not skipped");
    [pf release];
  }

  /* The regex exposes the include delimiter so quoted (project-local) and
     angle (external) includes can be told apart; only the latter can be
     installable system packages.  ProjectCenter's failing headers were all
     quoted includes of project-private (or orphaned) files. */
  {
    NSString *src = @"#import \"Local.h\"\n#import <System.h>\n";
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 2, "quoted and angle includes both matched");
    NSString *d0 = [src substringWithRange:[matches[0] rangeAtIndex:1]];
    NSString *d1 = [src substringWithRange:[matches[1] rangeAtIndex:1]];
    PASS([d0 isEqualToString:@"\""], "first include is quoted (project-local)");
    PASS([d1 isEqualToString:@"<"], "second include is angle (external)");
  }

  /* A repository often carries sources for other platforms next to the ones
     the makefiles build; only the listed ones may be scanned, or the build is
     refused over headers it never needs. */
  {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat: @"t_Preflight-%d", (int)getpid()]];
    NSString *sub = [root stringByAppendingPathComponent: @"Lib"];
    [fm createDirectoryAtPath: sub withIntermediateDirectories: YES
                   attributes: nil error: NULL];

    [@"#import <AppKit/AppKit.h>\n" writeToFile:
      [root stringByAppendingPathComponent: @"Built.m"]
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];
    [@"#import <UIKit/UIKit.h>\n" writeToFile:
      [root stringByAppendingPathComponent: @"ForAnotherPlatform.m"]
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];
    [@"#import <Foundation/Foundation.h>\n" writeToFile:
      [sub stringByAppendingPathComponent: @"Sub.m"]
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];
    [@"Lib_OBJC_FILES = Sub.m\n" writeToFile:
      [sub stringByAppendingPathComponent: @"GNUmakefile"]
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];

    NSString *makefile = [root stringByAppendingPathComponent: @"GNUmakefile"];
    [@"App_SUBPROJECTS = Lib\nApp_OBJC_FILES = \\\n\tBuilt.m\n" writeToFile: makefile
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];

    GWBuildPreflight *pf = [[GWBuildPreflight alloc] initWithSourceRoot: root
                                                          makefilePath: makefile];
    NSArray *files = [pf collectSourceFiles];
    NSMutableSet *names = [NSMutableSet set];
    for (NSString *f in files) [names addObject: [f lastPathComponent]];

    PASS([names containsObject: @"Built.m"], "a source the makefile lists is scanned");
    PASS([names containsObject: @"Sub.m"], "a source of a subproject is scanned");
    PASS(![names containsObject: @"ForAnotherPlatform.m"],
         "a source no makefile builds is not scanned");
    [pf release];
    [fm removeItemAtPath: root error: NULL];
  }

  /* A UIKit or Mach header behind a target conditional of another Apple
     platform is dead code here and must not be demanded. */
  {
    GWBuildPreflight *pf = [GWBuildPreflight new];
    NSString *src = @"#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE\n"
                     "#import <CFNetwork/CFNetwork.h>\n#endif\n"
                     "#ifdef __MACH__\n#include <mach-o/arch.h>\n#endif\n";
    NSMutableDictionary *macros = [pf _macroEnvironment];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src macros:macros lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 2, "both Apple-only imports are matched");
    PASS([pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                              actives:actives inBlocks:inBlocks ranges:ranges],
         "an import under TARGET_OS_IPHONE is skipped");
    PASS([pf _shouldSkipHeaderAtMatch:matches[1] inContent:src
                              actives:actives inBlocks:inBlocks ranges:ranges],
         "an import under __MACH__ is skipped");
    [pf release];
  }

  /* A project switches features off with -D flags in its makefile, and the
     sources guard the feature's imports with the same macro.  Without reading
     those flags the preflight demands the libraries of every feature the
     build does not compile. */
  {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat: @"t_PreflightD-%d", (int)getpid()]];
    [fm createDirectoryAtPath: root withIntermediateDirectories: YES
                   attributes: nil error: NULL];
    NSString *makefile = [root stringByAppendingPathComponent: @"GNUmakefile"];
    [@"PORTS = -DENABLE_IRC=1 -DENABLE_SILC=0 -UHAVE_WIDGET\n"
      "ADDITIONAL_CPPFLAGS += $(PORTS)\nApp_OBJC_FILES = Built.m\n"
      writeToFile: makefile atomically: YES encoding: NSUTF8StringEncoding error: NULL];

    GWBuildPreflight *pf = [[GWBuildPreflight alloc] initWithSourceRoot: root
                                                          makefilePath: makefile];
    NSString *src = @"#if ENABLE(SILC)\n#include <libsilc/silcincludes.h>\n#endif\n"
                     "#if ENABLE(IRC)\n#include <irc/irc.h>\n#endif\n"
                     "#ifdef HAVE_WIDGET\n#include <widget/widget.h>\n#endif\n"
                     "#undef ENABLE_IRC\n#if ENABLE(IRC)\n#include <irc/late.h>\n#endif\n";
    NSMutableDictionary *macros = [pf _macroEnvironment];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src macros:macros lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 4, "all four guarded imports are matched");
    PASS([pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                              actives:actives inBlocks:inBlocks ranges:ranges],
         "an import of a feature switched off with -D is skipped");
    PASS(![pf _shouldSkipHeaderAtMatch:matches[1] inContent:src
                               actives:actives inBlocks:inBlocks ranges:ranges],
         "an import of a feature switched on with -D is required");
    PASS([pf _shouldSkipHeaderAtMatch:matches[2] inContent:src
                              actives:actives inBlocks:inBlocks ranges:ranges],
         "an import under a macro the makefile undefines is skipped");
    PASS([pf _shouldSkipHeaderAtMatch:matches[3] inContent:src
                              actives:actives inBlocks:inBlocks ranges:ranges],
         "an import after the file undefines the switch is skipped");
    [pf release];
    [fm removeItemAtPath: root error: NULL];
  }

  /* A repository carries headers for code it does not build; one is only part
     of the build when something compiled imports it, directly or through
     another header. */
  {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat: @"t_PreflightR-%d", (int)getpid()]];
    [fm createDirectoryAtPath: root withIntermediateDirectories: YES
                   attributes: nil error: NULL];
    [@"#import \"Reached.h\"\n" writeToFile:
      [root stringByAppendingPathComponent: @"Built.m"]
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];
    [@"#include <reached/reached.h>\n" writeToFile:
      [root stringByAppendingPathComponent: @"Reached.h"]
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];
    [@"#include <orphan/orphan.h>\n" writeToFile:
      [root stringByAppendingPathComponent: @"Orphan.h"]
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];
    NSString *makefile = [root stringByAppendingPathComponent: @"GNUmakefile"];
    [@"App_OBJC_FILES = Built.m\n" writeToFile: makefile
      atomically: YES encoding: NSUTF8StringEncoding error: NULL];

    GWBuildPreflight *pf = [[GWBuildPreflight alloc] initWithSourceRoot: root
                                                          makefilePath: makefile];
    GWHeaderDatabase *db = [GWHeaderDatabase sharedDatabase];
    if (![db isOpen]) {
      PASS(YES, "headers.db not readable; skipped reachability case");
    } else {
      [pf resolveMissingPackagesInFiles: [pf collectSourceFiles]
                              database: db
                                distro: [db databaseDistroForCurrentOS]];
      NSString *unresolved = [[pf unresolvedHeaders] componentsJoinedByString: @" "];
      PASS([unresolved rangeOfString: @"reached/reached.h"].location != NSNotFound,
           "a header an imported header needs is required");
      PASS([unresolved rangeOfString: @"orphan/orphan.h"].location == NSNotFound,
           "a header nothing compiled imports is not required");
    }
    [pf release];
    [fm removeItemAtPath: root error: NULL];
  }

  [arp release];
  return 0;
}
