# AppGarden - implementation brief for the coding agent

You are implementing AppGarden, the app store of the Gershwin desktop, as a
native GNUstep application in this directory (`gershwin-components/AppGarden`).
This document is the complete specification. Read it once top to bottom before
writing any code, then read the files listed in section 2. Where this brief
and the live data disagree, the live data wins; where this brief and repo
conventions disagree, ask the user.

The user's one-line request was: "an elegant app store that consumes
https://appimage.github.io/feed.json. Must be sleek and Mac-like and in good
GNUstep architecture." Everything below serves that sentence.

Sections:

1. Ground rules
2. Read these files first
3. What the app does (user-level description)
4. Architecture
5. The catalog model and parser
6. Catalog cache and refresh
7. Images
8. Resolving the download and installing
9. The user interface, screen by screen
10. Menus and keyboard
11. Preferences (user defaults)
12. Build files: GNUmakefile, Info.plist, icon
13. Tests
14. Acceptance checklist
15. Things not to do
16. Handing over

---------------------------------------------------------------------------

## 1. Ground rules

These come from the repository's `AGENTS.md`, the user's global rules, and
the peer sessions working in this checkout. They are not optional.

Repository and git

- Work on branch `dev` (or a branch off `dev`). Never commit to `main`.
- NEVER commit or push unless the user explicitly says "commit" or "push".
  When they do, commit only files under `AppGarden/` plus the one-line
  top-level `GNUmakefile` change from section 12. The shared checkout carries
  other people's uncommitted edits under `Assistants/` and `Network/`; do not
  stage them.
- Commit message style for this repo: `AppGarden: <what was achieved>`, then
  paragraphs that each say what was wrong or missing, what the user gains,
  and how it was done. No headlines, no unicode, no attribution lines of any
  kind ("Generated with", "Co-Authored-By" and the like are forbidden).
- Before starting, run `ListAgents` and message every peer session with what
  you are about to touch (this directory and the top-level GNUmakefile), and
  ask what they work on. Wait for answers. One peer (a Battery menu extra) has
  a pending change to the `LIBRARY_CONSUMERS` line of the top-level
  GNUmakefile; tell them you add `AppGarden` to that line so the merge is
  trivial.

Language and toolchain

- Objective-C with ARC: `ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions`.
  Runtime is `gnustep-2.0`, compiler is clang. Blocks are fine.
- `NSOperationQueue` for background work, `[NSOperationQueue mainQueue]` to
  hop back. Do not use libdispatch for concurrency (`dispatch_async` and
  friends): this runtime's GCD is unreliable, which is why every network
  component in this repo uses `NSOperationQueue` (see `Books/OPDSFeedParser.m`
  and `PackageManager/GWAppImageDownloader.m`).
- Network I/O goes through the `curl` command line tool run with `NSTask`,
  exactly as the two files above do. `NSURLSession`/`NSURLConnection` are not
  used in this repo for downloads because they block the main thread on DNS
  and behave badly with redirects here. `curl` is a hard dependency of the
  desktop already (PackageManager, Books, SoftwareUpdate all need it).
- It must build and run on Linux, FreeBSD and OpenBSD. Do not call anything
  Linux-only. `curl`, `NSTask`, `NSFileManager` are enough for everything.
- No Gorm/nib files. All UI is built in code (see the `gnustep-code-built-ui`
  skill and, for a fully code-built app in this repo, `SoftwareUpdate/`).
- Layout metrics come from `AppearanceMetrics.h`. `SoftwareUpdate/` carries a
  copy; copy that same header into `AppGarden/` unchanged (do not edit it,
  the original lives in `gershwin-eau-theme`). Use its constants
  (`METRICS_CONTENT_SIDE_MARGIN`, `METRICS_SPACE_*`, `METRICS_BUTTON_HEIGHT`,
  `METRICS_TEXT_INPUT_FIELD_HEIGHT`, the `METRICS_FONT_*` macros) instead of
  literal numbers wherever a matching constant exists. Read the
  `gershwin-ui-metrics` skill for the AppKit coordinate system (y-up), top vs
  bottom anchoring and resize behavior.

Code style

- New files carry this header and nothing else above the first `#import`:

      /*
       * Copyright (c) 2026 Simon Peter
       *
       * SPDX-License-Identifier: BSD-2-Clause
       */

  (No file in this component is GPL, so no dual license.)
- Class prefix `AG`. File name equals class name (`AGCatalog.h/.m`).
- Comments explain WHY, never WHAT. A comment that paraphrases the next line
  of code is wrong and must be deleted. A comment that explains a non-obvious
  decision ("curl instead of NSURLSession because ...") is right.
- No em-dashes anywhere (code, comments, strings, docs). Plain `-`.
- Never mention Apple, Mac, macOS, Cocoa, NeXT in comments, strings or the
  Info.plist description. "Mac-like" is the user's shorthand for the visual
  target; the code and the product text never say it.
- Reverse-DNS identifier: `io.github.gershwin-desktop.AppGarden`. Never
  `org.gershwin.*`.
- Fail hard, no fallbacks. A missing `curl`, an unparsable feed, an HTTP
  error, a download that produced no file: each is an `NSError` with a
  human-readable `NSLocalizedDescriptionKey` that reaches the user in an
  alert or an inline error view. Do not silently retry forever, do not
  swallow errors into `NSLog`, do not invent data. The only "graceful"
  behaviors are the ones this brief names explicitly (placeholder icon for
  missing or SVG icons, cached catalog when offline, "Open Download Page"
  when no AppImage can be resolved), because those are product features,
  not error hiding.
- No code duplication. If two views draw the same rounded card, there is one
  view class. If the detail page and the card both need an install button,
  there is one `AGInstallButton`. Download and GitHub release resolution
  already exist in `PackageManager.framework` (`GWAppImageDownloader`); link
  it, do not copy it.
- Warnings are errors in practice: build with `-Wall -Wextra` and finish with
  a clean build that prints no warning. Fix the cause, never silence with
  pragmas.
- The `.m` files never contain hard-coded English that the user sees without
  going through `NSLocalizedString(@"...", @"")` or the `_()` macro. Ship
  `Resources/English.lproj/Localizable.strings` (see `Assistants/AssistantFramework/Resources/en.lproj/`
  for the format; use `English.lproj`, the GNUstep default).

Install domain

- `GNUSTEP_INSTALLATION_DOMAIN = SYSTEM` in the GNUmakefile, first line after
  `common.make`. The app installs to `/System/Applications/AppGarden.app`.
  Never install to LOCAL. After every `sudo gmake install` verify that
  nothing landed in `/Local/Applications`, `/Local/Library/*`.
- Before installing to SYSTEM ask the user; after installing, ask the user to
  test before anything is committed.

Desktop testing

- Never click around on the user's live desktop (display `:0`). Use an
  isolated uitest slot (see the `gnustep-wm-headless-testing` skill) or ask
  the user to test. For automated UI checks use DriveUI (`driveui` skill) and
  `.uitest` files (`Stickies/Tests/stickies.uitest` is a good example of the
  syntax).

---------------------------------------------------------------------------

## 2. Read these files first

In this order. They define the idioms you must match.

| File | What to take from it |
| --- | --- |
| `AGENTS.md` (repo root) | Build/install commands, layout, conventions. |
| `FEED.md` (this directory) | The data. Every irregularity your parser must survive. |
| `DOWNLOADS.md` (this directory) | How a Get works out which release and which file inside it to fetch: the rules, why each exists, the real releases each was written for, and what was wrong before. |
| `PackageManager/GWAppImageAssetPicker.h/.m` | The rules that choose one AppImage out of one release's asset names. Foundation-only, with no network, so the same rules the catalog's own site uses (AppImage/appimage.github.io, `code/find-appimage.sh`) can be tested against real release names. You never call it; the downloader does. |
| `Fixtures/feed-sample.json` | The unit-test input. |
| `PackageManager/GWAppImageDownloader.h/.m` | How an AppImage is downloaded into the user's Applications folder and which GitHub release and which file inside it are used for this machine. You call this; you do not reimplement it. |
| `PackageManager/GWPackageManager.h` | `GWInstallProgressHandler` protocol (`installDidProgress:message:`, `installDidOutputLine:`) that the downloader reports through. |
| `SoftwareUpdate/GNUmakefile` | How an app in this repo links `PackageManager.framework` (include path, `-L`, `-rpath`), enables ARC, sets warnings. Your GNUmakefile is modeled on it. |
| `SoftwareUpdate/Controllers/SWMainWindowController.m` | A fully code-built window controller in this repo using `AppearanceMetrics.h`. |
| `Books/OPDSFeedParser.m` | The `NSOperationQueue` + `curl` fetch pattern with completion blocks delivered on the main queue. Your `AGFeedLoader` and `AGImageCache` follow it. |
| `Books/BookshelfView.m` | A custom grid-of-tiles view in this repo (drawing, hit testing, selection). Your `AGAppGridView` is the same kind of object. |
| `Build/CatalogController.m` | Search field wiring and `NSSearchFieldCell` under the Eau theme, keyboard movement from the search field into results. |
| `Stickies/Tests/Unit/GNUmakefile.preamble` and `GNUmakefile` | How ObjectTesting test tools link app sources as collaborators. |
| `Stickies/Tests/stickies.uitest` | `.uitest` syntax. |
| `make_services/README.md` | Which directories the desktop scans for applications, so you can verify that an installed AppImage is actually registered (section 8). |
| `/Developer/Library/Sources/gershwin-workspace/Workspace/WorkspaceApplication.m` around line 500 | How the file manager launches an AppImage (plain executable, no bundle). |

Skills to load: `gnustep-code-built-ui`, `gershwin-ui-metrics`,
`gnustep-red-green-tdd`, `gnustep-info-plist`, `driveui`. Load the GNUstep
skill mentioned in the user's global rules if it is listed.

---------------------------------------------------------------------------

## 3. What the app does

A user opens AppGarden from the Applications folder or the Dock. A single
window appears: a sidebar on the left with "Discover", "Downloaded" and a
list of categories; a large content area on the right showing a grid of
application cards (icon, name, one-line description, Get button). A search
field sits at the top right of the content area. Typing filters the grid as
you type. Discover shows the whole catalog in a random order, and keeps
that order for as long as the catalog is loaded.

Clicking a card opens the detail page in the same content area: big icon,
name, author, category, license, a Get button, the screenshot, the full
description, and links to the project on GitHub and to its page on
appimage.github.io. A back arrow at the top left returns to the grid.

Clicking Get on a card or on the detail page downloads the AppImage into the
user's Applications folder. The button turns into a progress bar while the
download runs and into Open when done. Open launches the app. The Installed
section lists everything AppGarden installed, each with an Open and a Remove
button. Remove asks for confirmation and deletes the AppImage file.

The catalog is fetched on launch; while fetching, a centered spinner and the
text "Loading catalog..." is shown. If fetching fails and a cached catalog
exists, the cached catalog is shown with a slim banner "Showing the catalog
from <date>. Could not reach appimage.github.io: <error>" and a Retry button.
If fetching fails and there is no cache, the content area shows the error and
a Retry button and nothing else.

That is the whole product. No accounts, no ratings, no comments, no
purchasing, no update checking in version one. Do not add features that are
not in this brief.

---------------------------------------------------------------------------

## 4. Architecture

Model - Service - Controller - View, in that dependency order. Lower layers
never import higher ones. Foundation-only classes (Models and most Services)
are tested headless with ObjectTesting; AppKit appears only in Controllers and
Views.

    AppGarden/
      GNUmakefile
      AppGardenInfo.plist
      AppearanceMetrics.h            (copied from SoftwareUpdate/, unchanged)
      main.m
      Models/
        AGCatalog.h/.m               the parsed feed: items, categories, lookup by name
        AGApp.h/.m                   one item; immutable value object
        AGLink.h/.m                  {type, url} with resolved absolute URL
        AGAuthor.h/.m                {name, url}
        AGFeedParser.h/.m            NSData -> AGCatalog or NSError
        AGCategoryNames.h/.m         freedesktop category -> display name, ordering, grouping
        AGLicenseFormatter.h/.m      license string -> display string + optional URL
        AGSearchIndex.h/.m           filter items by query and category, ranking
        AGDownloadResolver.h/.m      AGApp -> how to obtain the AppImage (enum + payload), pure logic
        AGGridLayout.h/.m            pure geometry for the card grid (columns, frames), no AppKit
        AGDiscoverOrder.h/.m         the random order Discover lists the catalog in, no AppKit
      Services/
        AGFeedLoader.h/.m            fetch feed.json with curl, conditional GET, cache file
        AGImageCache.h/.m            async icon/screenshot loading, memory + disk cache
        AGInstaller.h/.m             wraps GWAppImageDownloader; install/remove/launch; installed-state queries
        AGInstallTask.h/.m           one running install: progress, message, state, error
        AGInstallRegistry.h/.m       remembers what AppGarden installed (plist in ~/Library/AppGarden)
      Controllers/
        AGAppDelegate.h/.m           menus, main window, open on launch
        AGMainWindowController.h/.m  window, sidebar/content split, navigation stack, search
        AGSidebarController.h/.m     sidebar table: Discover, Installed, categories
        AGGridViewController.h/.m    grid page for a filter (all / category / installed / search)
        AGDetailViewController.h/.m  detail page for one AGApp
        AGStatusBannerController.h/.m  the "cached catalog" / error banner
      Views/
        AGAppCardView.h/.m           one card: icon, name, subtitle, install button
        AGAppGridView.h/.m           hosts cards in an NSScrollView, uses AGGridLayout, keyboard navigation
        AGInstallButton.h/.m         Get / progress / Open / Open Page states; one class used everywhere
        AGScreenshotView.h/.m        letterboxed image with rounded corners and placeholder
        AGPlaceholderIcon.h/.m       draws the generic app icon used when the feed has none
        AGSourceListCell.h/.m        sidebar row cell (icon + label, section headers)
      Resources/
        AppGarden.png, AppGarden@2x.png    app icon (section 12)
        Placeholder.png                    generic app icon (or draw it in code, then no file)
        English.lproj/Localizable.strings
      Tests/
        Unit/                        ObjectTesting tools (section 13)
        appgarden.uitest             DriveUI smoke test

Rules for the layers:

- `Models/` import only Foundation. No `NSImage`, no `NSColor`.
- `Services/` import Foundation and, for `AGImageCache` only, AppKit's
  `NSImage` (it must produce images). `AGInstaller` imports
  `<PackageManager/GWAppImageDownloader.h>` and `<PackageManager/GWPackageManager.h>`.
- Controllers own Views and observe Services. Views never talk to Services;
  they get data pushed in and report clicks through target/action or a small
  delegate protocol.
- Everything that changes UI runs on the main thread. Services deliver
  results with completion blocks that are already on the main queue, exactly
  like `OPDSFeedParser` does (`[[NSOperationQueue mainQueue] addOperationWithBlock:]`).
- One shared `AGImageCache` and one shared `AGInstaller` are created by
  `AGAppDelegate` and handed down by init parameters. No singletons except
  the ones AppKit forces (`NSApp`, `NSUserDefaults`).
- Notifications: `AGInstaller` posts `AGInstallerTaskDidChangeNotification`
  (object: the `AGInstallTask`) on the main thread whenever a task's progress
  or state changes, and `AGInstallerInstalledSetDidChangeNotification` when
  something was installed or removed. Cards, the detail page and the
  Installed page observe these to update their `AGInstallButton`. This keeps
  a card that scrolled out of view and back in sync without polling.

---------------------------------------------------------------------------

## 5. The catalog model and parser

### AGApp

Immutable. Properties (all `readonly`, `copy` for strings and arrays):

    NSString *name;                 // "Apache_NetBeans", the identifier
    NSString *displayName;          // "Apache NetBeans": underscores replaced by spaces
    NSString *summary;              // first sentence or first line of description, max 90 chars, nil if no description
    NSString *descriptionText;      // full description or nil
    NSArray<NSString *> *categories;// nils dropped, empty array if none
    NSArray<AGAuthor *> *authors;   // empty array if none
    NSString *license;              // raw string or nil
    NSArray<AGLink *> *links;       // empty array if none
    NSURL *iconURL;                 // absolute, nil if no icon or icon is svg/svgz/DirIcon
    NSURL *screenshotURL;           // absolute or nil
    NSURL *githubURL;               // https://github.com/<owner>/<repo> or nil
    NSString *githubRepo;           // "owner/repo" or nil
    NSURL *downloadPageURL;         // the Download or Install link or nil
    NSURL *catalogPageURL;          // https://appimage.github.io/<name>/
    BOOL selfContained; NSString *glibcRequired; // optional metadata, shown in detail if present

Derivation rules (test each in `t_AGFeedParser`):

- `displayName`: replace `_` with space. Nothing else.
- `summary`: take `descriptionText`, cut at the first `\n`, then at the first
  `. ` if the result is longer than 90 characters, trim whitespace; if still
  longer than 90, cut at 89 and append an ellipsis character (U+2026). Nil
  when there is no description.
- `categories`: drop `null` entries. Keep the original order.
- `iconURL`: `https://appimage.github.io/database/` + path, but only when
  the path's extension is `png`, `jpg` or `jpeg` (case-insensitive).
  Otherwise nil (see FEED.md, "Assets").
- `screenshotURL`: same base, any extension.
- `githubRepo`: the `url` of the link with `type == "GitHub"` if it matches
  `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`. `githubURL` is derived from it. If a
  `Download` link matches `^https://github\.com/([^/]+)/([^/]+)/releases/?$`
  and there is no GitHub link, derive `githubRepo` from that instead (test
  with a synthetic item; the live feed always has both).
- `downloadPageURL`: the `Download` link, or the `Install` link if there is
  no `Download`. Must parse as a URL with scheme http or https, else nil.

### AGCatalog

    @property (readonly) NSArray<AGApp *> *apps;        // sorted by displayName, case-insensitive, localized (the canonical order; the Discover page shuffles it, see AGDiscoverOrder)
    @property (readonly) NSArray<NSString *> *categories; // distinct, ordered by AGCategoryNames
    @property (readonly) NSDate *fetchDate;               // when this data was downloaded
    - (AGApp *)appNamed:(NSString *)name;
    - (NSArray<AGApp *> *)appsInCategory:(NSString *)category;

### AGFeedParser

    + (AGCatalog *)catalogFromData:(NSData *)data fetchDate:(NSDate *)date error:(NSError **)error;

Errors (domain `AGErrorDomain`, codes in `AGError.h`): not JSON, top level
not a dictionary, `items` missing or not an array. An item that is not a
dictionary or has no string `name` is skipped with a single `NSLog` per feed
naming how many were skipped; everything else about an item is optional.
Use `NSJSONSerialization`. The feed contains non-ASCII text; do not touch
encodings, `NSJSONSerialization` handles UTF-8.

### AGCategoryNames

A table from freedesktop category to `{displayName, sortOrder}` for the
categories that occur in the feed (list in FEED.md), e.g.
`AudioVideo -> "Audio & Video"`, `Development -> "Developer Tools"`,
`Game -> "Games"`, `Network -> "Internet"`, `Office -> "Productivity"`,
`Graphics -> "Graphics & Design"`, `Utility -> "Utilities"`,
`Science -> "Science"`, `System -> "System"`, `Education -> "Education"`,
`Finance -> "Finance"`. Categories that are toolkits or desktops rather than
purposes (`Qt`, `GTK`, `GNOME`, `Application`) are hidden from the sidebar
and from the detail page. Anything not in the table shows under its raw name
after the known ones, alphabetically. Sidebar order: known ones by
`sortOrder`, then unknown ones alphabetically. Every display name goes
through `NSLocalizedString`.

### AGLicenseFormatter

    + (NSString *)displayStringForLicense:(NSString *)raw;  // nil -> "Unknown license"
    + (NSURL *)licenseURLForLicense:(NSString *)raw;         // the part after "=" in LicenseRef-...=<url>, else nil

`LicenseRef-proprietary` and `LicenseRef-proprietary=...` display as
"Proprietary". `NOASSERTION` displays as "Unknown license". `GPL-3.0+` and
`GPL-3.0-or-later` both display as "GPL-3.0 or later". Everything else is
shown verbatim.

### AGSearchIndex

    - (instancetype)initWithCatalog:(AGCatalog *)catalog;
    - (NSArray<AGApp *> *)appsMatchingQuery:(NSString *)query inCategory:(NSString *)categoryOrNil;

Query is split on whitespace; every term must match (case- and
diacritic-insensitive, `NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch`)
in `displayName`, `descriptionText`, `categories` display names or any author
name. Ranking: name prefix match first, then name contains, then description
matches; ties by `displayName`. An empty query returns the category's apps in
catalog order. Search results are therefore alphabetical within their rank and
never follow Discover's shuffle: a typed query is a question with an answer, not a
browse. Must handle 1551 items without noticeable delay on each
keystroke; a linear scan with `rangeOfString:` is fast enough, measure once
with a quick timing test tool and note the number in the PR text.

### AGDiscoverOrder

    + (NSArray *)shuffled:(NSArray *)apps;

Foundation only, so the permutation can be pinned down without a window
(`Tests/Unit/t_AGDiscoverOrder.m`). Returns a copy of `apps` in random order:
the same elements, each exactly once, never nil (`nil` in gives an empty list
out). Untyped, so a test can shuffle anything.

The window controller calls this once per catalog, in `catalogDidLoad:`, and
holds the result in `_discoverApps`. That placement is the whole point: a page
that reshuffles on every repopulate moves the cards under the user, resets the
scroll offset and drops the focused card, because `AGAppGridView -setApps:`
treats any changed array as a new list. Only Discover is shuffled. A category
page and the Downloaded list are lists of things the user went looking for and
keep the catalog's alphabetical order, which is a fact about the apps rather
than an arrangement of them.

### AGDownloadResolver

Pure function of an `AGApp` and the current architecture string (`x86_64` or
`aarch64`, obtained from `uname(2)` through `<sys/utsname.h>` - not `NSTask` -
falling back to `"unknown"`, once at startup in `AGInstaller`, passed in for
testability):

    typedef NS_ENUM(NSInteger, AGDownloadKind) {
        AGDownloadKindGitHubLatestRelease, // payload: githubRepo
        AGDownloadKindDirectURL,           // payload: URL of an .AppImage file
        AGDownloadKindWebPageOnly,         // payload: downloadPageURL; we cannot fetch a file
        AGDownloadKindNone                 // no links at all
    };
    + (AGDownloadKind)kindForApp:(AGApp *)app payload:(id *)payload;

The resolver decides **where an application comes from**, never which file.
It never looks at a release: `GitHubLatestRelease` is a promise to ask the
framework, and the rules for choosing a release and a file inside it live
there (section 8, "Which release, and which file in it"). The name
`GitHubLatestRelease` is historical - "latest" now means the newest release
that actually ships an AppImage, preferring the newest that is not a
pre-release.

Rules, in order:

1. `githubRepo` present -> `GitHubLatestRelease`. The payload is the repo
   only, but `AGInstaller` also hands the downloader the app's name, because
   one release can hold AppImages of several different programs and the
   catalog's name for the app is what tells them apart (FreeCAD's repository
   is `FreeCAD` while the catalog calls it `FreeCAD2`; Obsidian's is
   `obsidian-releases`).
2. `downloadPageURL` ends with `.AppImage` (case-insensitive) -> `DirectURL`.
3. `downloadPageURL` ends with `.AppImage.mirrorlist` -> `DirectURL` with
   the `.mirrorlist` suffix removed (openSUSE serves the file at that URL; if
   the name contains `x86_64` and the architecture is not `x86_64`, that is
   `WebPageOnly` instead, because there is no other build).
4. `downloadPageURL` present -> `WebPageOnly`.
5. otherwise `None`.

### AGGridLayout

    - (instancetype)initWithCardSize:(NSSize)size minimumGap:(CGFloat)gap sideInset:(CGFloat)inset;
    - (NSUInteger)columnsForWidth:(CGFloat)width;         // at least 1
    - (CGFloat)horizontalGapForWidth:(CGFloat)width;      // gap grows so cards spread evenly, never shrinks below minimum
    - (NSRect)frameForIndex:(NSUInteger)i width:(CGFloat)width; // y-up, first row at the top
    - (CGFloat)heightForCount:(NSUInteger)n width:(CGFloat)width;
    - (NSInteger)indexAtPoint:(NSPoint)p width:(CGFloat)width count:(NSUInteger)n; // -1 if in a gap

Cards are 200 x 232 points, minimum gap 20, side inset 24 (that is
`METRICS_CONTENT_SIDE_MARGIN`). The extra horizontal space is distributed
into the gaps, not added as a right margin, so the grid is centered.

---------------------------------------------------------------------------

## 6. Catalog cache and refresh

`AGFeedLoader`:

    - (void)loadWithCompletion:(void (^)(AGCatalog *catalog, BOOL fromCache, NSError *error))completion;
    - (void)reloadIgnoringCacheWithCompletion:...;
    @property (readonly) NSString *cachePath;

Cache directory: `~/Library/Caches/io.github.gershwin-desktop.AppGarden/`
(create with intermediate directories). Files: `feed.json` and
`feed.json.date` (ISO 8601 date of the last successful download, written
with `NSISO8601DateFormatter`).

Behavior of `load`:

1. If `feed.json` exists and its date is younger than 6 hours, parse it and
   complete with `fromCache = YES`, no network at all. Startup must feel
   instant on the second launch.
2. Otherwise run `curl -fsSL --max-time 60 -z <cachefile> -o <tmpfile> <feedURL>`
   on the background queue. `-z` makes curl send `If-Modified-Since` and
   return no body on 304; then curl exits 0 with an empty or missing tmp
   file: keep the cache, touch the date file, complete with the cached
   catalog. On exit 0 with a non-empty file: parse it FIRST; only when parsing
   succeeds move it over the cache and write the date. A feed that does not
   parse must not destroy a good cache.
3. On curl failure (non-zero exit): if a cache exists, parse it and complete
   with `fromCache = YES` AND the `NSError` (both non-nil), so the UI can show
   the banner. If no cache exists, complete with `catalog = nil` and the error.
   The error text includes curl's stderr, first line only, e.g.
   "Could not download the catalog: curl: (6) Could not resolve host: appimage.github.io".

`reloadIgnoringCache` skips step 1 and omits `-z`.

The feed URL is a constant `AGFeedURLString` in `AGFeedLoader.h`, overridable
by the user default `AGFeedURL` (for testing against a local file server).

---------------------------------------------------------------------------

## 7. Images

`AGImageCache`:

    - (instancetype)initWithCacheDirectory:(NSString *)dir;
    - (NSImage *)cachedImageForURL:(NSURL *)url;          // memory hit or nil, synchronous, main thread
    - (void)imageForURL:(NSURL *)url completion:(void (^)(NSImage *image, NSError *error))completion;
    - (void)cancelRequestsForURL:(NSURL *)url;   // optional but useful for fast scrolling

- Disk cache: same `Caches` directory as the feed, subdirectory `images/`.
  The file name is the URL's path percent-escaped with
  `stringByAddingPercentEncodingWithAllowedCharacters:` where only
  alphanumerics, `.`, `-` and `_` are allowed. GNUstep Foundation exposes no
  hash function, and the feed's paths are short, so this stays a valid file
  name on every platform we support and is trivially reversible when
  debugging. Say so in the code comment.
- Memory cache: `NSCache` keyed by URL string, `countLimit` 400. Icons are
  small; screenshots are decoded on demand and evicted first (do not raise the
  limit for them).
- Loading: one `NSOperationQueue`, `maxConcurrentOperationCount = 4`. Each
  operation checks the disk first, else runs `curl -fsSL --max-time 30 -o <tmp> <url>`,
  then moves the file into place, then creates the `NSImage` with
  `initWithContentsOfFile:` ON THE BACKGROUND operation (decoding is the
  expensive part) and delivers on the main queue. An `NSImage` that has zero
  representations is an error ("Not an image"), delete the file.
- Coalescing: two requests for the same URL while a download is in flight
  share one operation (keep an `NSMutableDictionary<NSString *, NSMutableArray *>`
  of pending completions, guarded by an `NSLock`).
- Failure is delivered as an `NSError`; the caller shows the placeholder.
  Do not retry automatically; a later scroll-in will request again (the
  failed URL is remembered for the session in an `NSMutableSet` so a dead
  URL is requested at most once per launch; that is not a fallback, it stops
  a request storm).

Asset origin: icons and screenshots are fetched only from
`https://appimage.github.io/database/...` (GitHub Pages, no rate limit), the
URLs the parser already built. Never rewrite them to
`raw.githubusercontent.com`, never fetch anything from `api.github.com`
while browsing, never fetch a project's own README or website for text.
Descriptions come from `feed.json`, which is served by the same host. The
AppGarden causes no GitHub API request at all, not even when the user clicks
Get: the release lookup inside `GWAppImageDownloader` reads github.com's own
web pages, because the API's 60 anonymous requests per hour are what once
made every Get fail with 403 for the rest of the hour.

Do not preload all 1300 icons at startup. Cards request their icon when they
are laid out visible (`AGAppGridView` asks the cache for the icons of the
visible index range on every scroll, with a 200-point look-ahead below the
viewport). Measure with `top` that scrolling the full grid stays smooth.

---------------------------------------------------------------------------

## 8. Resolving the download and installing

### Where installed apps live

`GWAppImageDownloader` puts the file at
`+[GWAppImageDownloader launcherPathForAppName:]`, currently
`~/Applications/<Display Name>.AppImage`. That is the location the rest of
the desktop expects from PackageManager (`NSAllApplicationsDirectory` is
`~/Applications`), so AppGarden uses the same call and never hard-codes the
path. An install made before the folder moved is still in
`~/Library/Applications`, and
`+[GWAppImageDownloader existingLauncherPathForAppName:]` is the call that
finds an app in either place: everything that asks "is this installed, and
where" (the state of the button, removal, Open) goes through it, not through
the download path.

Required verification, part of the acceptance checklist: after a test
install, run `make_services` (it is in `/System/Library/Tools`) and check
that the new AppImage is listed as a found application, then confirm that
`[[NSWorkspace sharedWorkspace] launchApplication:]` with the display name
starts it. `make_services/README.md` lists the scanned directories. If the
installed app is not registered, do not work around it in AppGarden (no
symlinks, no `.desktop` files): stop and report to the user with the
evidence, because changing where PackageManager puts downloads is the user's
decision, not a workaround to be made here.

Open does not start the application. `-revealApp:error:` asks the Workspace
application over Distributed Objects to select the file in a viewer (what
"Show in File Viewer" does elsewhere), with a 5 second request and reply
timeout so a file manager that never answers costs an alert rather than a
window that hangs. A file that is gone, or a file manager that is not
running, is reported the same way - never silently ignored, and never
retried.

### Which release, and which file in it

Two decisions, and they are two different ones, both inside the framework and
both behind a single instance method. AppGarden supplies only the repository
(`AGDownloadResolver`) and the app's name (`AGInstaller`). The rules are not to
be copied into AppGarden; that is the case the "you call this, you do not
reimplement it" rule of section 1 was written for.

**Which release.** `+preferredTagForRepo:progress:` picks the newest release
that is neither a draft nor a pre-release *and* does hold an AppImage, and
failing that the newest that holds one, pre-release or not. Both halves earn
their place on real projects: Obsidian's newest release is a mobile-only
`.apk`, so a release merely having to exist is not enough, and qTox publishes
only pre-releases, so one has to be accepted when nothing else is on offer.
The walk back reads at most six entries of `releases.atom`
(`kGWMaxReleasesToWalk`), because a project that has stopped shipping
AppImages in its last six releases is not helped by a seventh request.

- The tag comes from each Atom entry's own `href=".../releases/tag/TAG"`, never
  from its `<title>`: the two disagree in both directions. Obsidian titles
  `v1.13.7` "1.13.7" with no v, AppFlowy titles `0.14.5` "v0.14.5" with one.
- Redirects are followed with `-L` on every request, and the
  `releases/latest` probe keeps the **last** `location:` that carries
  `/releases/tag/`. This is what makes a renamed repository work:
  `ipfs-shipyard/ipfs-desktop` became `ipfs/ipfs-desktop`, and the first
  `location:` of a renamed repository still ends in `/releases/latest` and
  names no tag, which is exactly how "GitHub release lookup failed" came up
  for an app that downloads perfectly well. Two of the eleven repositories
  measured on 2026-09-28 were renamed.
- A tag containing a slash is percent-encoded with
  `stringByAddingPercentEncodingWithAllowedCharacters:` before it goes into
  the path, which is how janhq/jan's `checkpoint/code-ui-...` tag is spelled.

**Which file.** `GWAppImageAssetPicker` answers it, with no network of its own
so that the rules can be tested against real release names. Five rules in
order, each a no-op unless it keeps a *strict subset* - which is what lets an
arm-only release pass through the "prefer x86-64" step untouched:

1. Keep only names **ending** in `.appimage`, case-insensitive. A
   checksum, `.zsync` or `.blockmap` file *contains* ".AppImage" and is about
   a hundred kilobytes; AppImageUpdate's release has twelve of them, and
   digiKam's file is lower case.
2. Drop the other architectures, matched on word boundaries so that the "arm"
   in "Armour" and the "64" in "macOS10" do not count. **This is the rule
   that does most of the work**: a release that also ships an arm build puts
   it first, and often uploads it first too. Obsidian 1.13.7 lists
   `Obsidian-1.13.7-arm64.AppImage` before `Obsidian-1.13.7.AppImage` and
   uploads it five seconds earlier, and the old "first name mentioning
   x86_64" rule found neither and fell back to the first AppImage - the arm
   binary, on an x86-64 machine.
3. Prefer the x86-64 spellings: `x86_64`, `x86-64`, `amd64`, `x64`,
   `linux64`, `64bit`. The catalog uses six of them, and the old code knew
   two.
4. Drop `debug`, `dbg`, `test`, `nightly` and `symbols`, from the **asset
   name only**. qTox's entire repository is called
   `qTox-nightly-releases` and its only usable AppImage is a nightly build, so
   a rule that looked at the repository, the tag or the URL would delete it
   from the catalog.
5. Prefer the asset whose name *skeleton* equals the app name's skeleton
   (`+stemForAssetName:`): lowercased, without the extension, a 7-to-40-digit
   hex git hash, `x86_64`/`x86-64`/`amd64`/`x64`/`linux64`/`linux`/`glibc`, or
   any digits. That is what tells three different programs in one release
   apart - AppImageUpdate's holds `AppImageUpdate`, `appimageupdatetool` and
   `validate`, for four architectures each, so picking the right x86-64 file
   still leaves the wrong program to choose.

Several left with the **same** skeleton are taken in name order: 4KWALL ships
`4kWall-2026.9.5-x86_64.AppImage` and `4kWall-x86_64.AppImage`, which are the
same bytes with the same upload time, and the catalog's own script refuses
that case, which would break an app that demonstrably works. Several left
with **different** skeletons are reported as `GWAppImagePickAmbiguous` rather
than guessed at, because either could be a different program.

This is a transliteration of the catalog's `code/find-appimage.sh` on purpose:
so that "the AppImage of this release" means in AppGarden what it means on
appimage.github.io, and a difference between the two is a bug in one of them
rather than a surprise for the user.

What the user is told when the picker refuses, which are new strings and the
only user-facing text this adds:

- `No release of <repo> has an AppImage`
- `No release of <repo> has an AppImage for this machine`
- `The newest release of <repo> has several AppImages and none of them is
  clearly the right one for this machine: <the names>`

The last one is the single case where the user may want to fetch a file by
hand, which is why it names the candidates instead of saying "failed". These
come from the framework, so they are English only; nothing in the app
localizes them.


### AGInstaller

    - (instancetype)initWithRegistry:(AGInstallRegistry *)registry;
    - (AGInstallState)stateForApp:(AGApp *)app;   // NotInstalled, Downloading, Installed, Failed
    - (AGInstallTask *)taskForApp:(AGApp *)app;   // the running/failed task or nil
    - (AGInstallTask *)installApp:(AGApp *)app;   // starts, returns immediately
    - (void)cancelTask:(AGInstallTask *)task;
    - (BOOL)launchApp:(AGApp *)app error:(NSError **)error;
    - (BOOL)removeApp:(AGApp *)app error:(NSError **)error;
    - (NSArray<AGApp *> *)installedAppsFromCatalog:(AGCatalog *)catalog; // registry entries that still exist on disk

- `stateForApp:` is `Installed` when the registry has the name AND the file at
  `launcherPathForAppName:` exists and is executable. A registry entry whose
  file is gone (user deleted it in the file manager) is dropped from the
  registry on the next query; that is state reconciliation, not a fallback.
- `installApp:` creates an `AGInstallTask`, adds an operation to a serial
  `NSOperationQueue` (one download at a time keeps bandwidth predictable and
  progress readable; a second Get click on another app queues it and its
  button shows "Waiting..."). The operation:
  1. Resolves with `AGDownloadResolver`. `WebPageOnly`/`None` never reach
     here (the button opens the page instead); if they do, that is a
     programming error: `NSAssert`.
  2. `GitHubLatestRelease`: calls
     `-[GWAppImageDownloader downloadAppImageFromGitHubRepo:appName:progress:error:]`
     with `appName = app.name` (the downloader itself turns underscores into
     spaces for the file name). The task object is the
     `GWInstallProgressHandler`; it forwards `installDidProgress:message:` to
     the main queue and posts the change notification.
  3. `DirectURL`: `downloadAppImageFromURL:appName:progress:error:`.
  4. On success: add to registry, state `Installed`, notification. On error:
     state `Failed`, `task.error` set, notification; the button shows "Failed"
     with the error as tooltip and clicking it shows the error in an `NSAlert`
     with a "Try Again" button. The text is the framework's own, which now
     usually says what went wrong rather than only which step failed (the three
     messages at the end of "Which release, and which file in it"). Do not
     replace those with a generic catch-all: they are what makes a refusal
     legible, and one of them names the files the user could fetch by hand.
- No GitHub API request is made, by the app or by the downloader: the
  downloader follows the `releases/latest` redirect chain with `curl -fsSIL`
  and then reads the Atom feed and the expanded-assets page. A Get costs two
  requests when the newest non-prerelease already holds an AppImage, and up to
  eight when it has to walk back through older releases. AppGarden itself
  makes none while browsing. Never call the GitHub API to decorate the
  catalog (no star counts,
  no release dates, no asset sizes). When the API answers 403 the downloader
  reports an error; make sure its text says "GitHub rate limit" when curl's
  output contains `rate limit` so the user understands (extend the error text
  in `AGInstallTask`, not in the framework).
- `launchApp:`: `[[NSWorkspace sharedWorkspace] launchApplication:app.displayName]`
  after a `make_services` refresh has happened once since install (run
  `make_services` with `NSTask`, wait for exit, once per install, on the
  background operation, so the desktop learns about the new app; this is the
  same thing the desktop does on login). If `launchApplication:` returns NO,
  run the AppImage directly with `NSTask` (launch path = the file, no
  arguments, current directory = home) and report an error only if that
  raises. Comment WHY: the workspace lookup needs the services cache while a
  plain executable can always be started.
- `removeApp:` deletes the file with `NSFileManager`, removes the registry
  entry, posts the notification. The confirmation dialog lives in the
  controller, not here.

### AGInstallRegistry

A plist at `~/Library/AppGarden/Installed.plist`: dictionary keyed by
`app.name` with `{path, installedAt, displayName}`. Read once at startup,
written atomically on every change. It exists so the Installed page knows what
AppGarden installed even when the catalog entry disappears later.

### AGInstallTask

    @property (readonly) AGApp *app;
    @property (readonly) AGInstallTaskState state; // Waiting, Downloading, Done, Failed, Cancelled
    @property (readonly) float progress;           // 0..1, -1 when indeterminate
    @property (readonly) NSString *message;        // "Resolving release...", "Downloading 34 MB..."
    @property (readonly) NSError *error;

`GWAppImageDownloader` reports coarse phases (0.1 downloading, 0.6 saving).
Byte-accurate progress is not available from its `curl` call without
changing the framework. Show the progress bar as indeterminate (barber pole)
while `progress` is between 0.1 and 0.6 and switch to determinate for the
rest. If you find that unsatisfying, propose a small framework change to the
user (curl `--progress-bar` parsed from stderr) instead of doing it in
AppGarden. Do not fork the downloader.

---------------------------------------------------------------------------

## 9. The user interface, screen by screen

Visual target: calm, light, generous whitespace, one accent color (the
system's selection color from `[NSColor selectedControlColor]`, never a
hard-coded blue), thin separators, rounded cards. Everything the Eau theme
draws (buttons, scrollers, search field, table selection) is left to the
theme. You draw only cards, the placeholder icon, the screenshot frame and
the install button's progress state.

### Window

- Title "AppGarden". Content size at first launch 1040 x 680, minimum
  760 x 480. Frame autosave name `AGMainWindow`. Style: titled, closable,
  miniaturizable, resizable. Closing the window quits the app
  (`applicationShouldTerminateAfterLastWindowClosed:` returns YES); the app is
  a single-window utility.
- Layout: `NSSplitView`, vertical divider, thin divider style if available,
  sidebar left fixed at 200 points (the split view delegate constrains min
  and max to 200, so the user cannot drag it; a fixed sidebar is simpler and
  the design does not need a resizable one), content right fills the rest.
  Autosave name `AGMainSplit` is NOT set (the width is fixed).

### Sidebar (`AGSidebarController`)

- A single-column `NSTableView` in an `NSScrollView` with no border, no
  header, row height 24, the theme's default table background (so the
  sidebar matches every other source list on this desktop; no custom tint).
  The split view divider separates it from the content; draw no extra line.
- Rows, top to bottom: section header "Library" (non-selectable, small caps
  bold 11 pt, gray), "Discover", "Installed", blank spacer row (height 12,
  non-selectable), section header "Categories", then one row per category
  from `AGCategoryNames`, each "Display Name" with the count of apps
  right-aligned in gray 11 pt.
- Icons: none. Text only, 13 pt system font, 12 points left inset for items,
  8 for headers. A source list without icons stays calm.
- Selection: full-row highlight from the theme. Selecting a row pushes the
  corresponding grid page and clears the search field. Arrow keys move the
  selection and the content follows.
- `AGSourceListCell` is an `NSTextFieldCell` subclass that knows whether it is
  a header, an item or a spacer and draws the count.

### Content area

A container `NSView` owned by `AGMainWindowController` with three layers:

1. Top bar, 52 points high, full width, background same as content, a
   1-point bottom separator in `[NSColor gridColor]`. Contains, left to
   right: a Back button (`NSButton`, bezel style rounded, title "Back",
   width 72, hidden when the navigation stack has one entry), the page
   title (`NSTextField` label, bold 20 pt, e.g. "Discover", "Developer
   Tools", "Search: foo", or the app name on detail), and at the right an
   `NSSearchField` 240 points wide, `METRICS_TEXT_INPUT_FIELD_HEIGHT` high,
   placeholder "Search", 24 points right inset. Copy the search field setup
   from `Build/CatalogController.m` so it works under the Eau theme.
2. Optional status banner (`AGStatusBannerController`), 32 points high under
   the top bar, pale yellow background `[NSColor colorWithCalibratedRed:1.0 green:0.96 blue:0.80 alpha:1.0]`,
   13 pt text, a small "Retry" button at the right. Shown only in the two
   situations of section 3. Pushing it in and out moves the page view; no
   animation needed.
3. The page view: whatever the top of the navigation stack shows. Pages are
   `NSViewController` subclasses whose `view` is sized to the page area and
   autoresizes with it.

Navigation stack: an `NSMutableArray` of view controllers, typed
`NSViewController<AGPage> *`. `AGPage` is a marker protocol and nothing more:
pages carry no title, because the top bar shows none and
`NSViewController`'s own `title` would be copied onto the window, which is
meant to stay "AppGarden".


### Grid page (`AGGridViewController` + `AGAppGridView` + `AGAppCardView`)

- `AGAppGridView` is a flipped `NSView` inside an `NSScrollView` (vertical
  scroller only, `autohidesScrollers` YES, no border, background
  `[NSColor windowBackgroundColor]`). It is flipped so that "first row at the
  top" is natural; `AGGridLayout` is written for a flipped view (say so in
  the header).
- One `AGAppCardView` per visible item, recycled: keep a pool, on every
  layout pass compute the visible index range, bind the pooled views to those
  indices. With 1551 items and recycling, memory stays small and the initial
  layout is instant. Non-visible cards do not exist.
- Card (200 x 232): white rounded rectangle (radius 10) with a 1-point
  border `[NSColor colorWithCalibratedWhite:0.0 alpha:0.08]`, no shadow
  (shadows cost redraw time in this stack and look heavy). Inside, top to
  bottom, centered horizontally: 16 points padding, icon 96 x 96 (the
  `NSImage` drawn with `NSCompositeSourceOver`, `respectFlipped` YES,
  interpolation high; the placeholder when nil), 12 points, name 13 pt bold
  centered, single line, truncating tail, 4 points, summary 11 pt gray
  centered, up to 2 lines, truncating tail (use an `NSTextField` label with
  `setMaximumNumberOfLines:` if available in this libs-gui; otherwise cut the
  string yourself with a text container measure; check the installed headers,
  do not guess), then the `AGInstallButton` 80 x 22 centered, 16 points from
  the bottom.
- Hover: when the mouse is over a card, its border becomes 2 points in the
  accent color at 50 percent alpha. Use tracking areas
  (`NSTrackingArea`, `NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow`)
  and update them in `updateTrackingAreas`. Only the hovered card redraws.
- Click anywhere on the card except the button opens the detail page. The
  button handles its own click.
- Keyboard: the grid view accepts first responder. Arrow keys move a focused
  card (drawn with the same 2-point accent border, full alpha), Return opens
  it, Space toggles Get/Open on it. Tab from the search field moves focus into
  the grid at the first card (mirror `Build/CatalogController.m`'s
  `exitSearchFieldIntoResultsWithDelta:`).
- Empty states, centered, 13 pt gray: "No applications match \"foo\"." on
  search, "You have not installed anything yet. Apps you get from AppGarden
  appear here." on Installed.
- Loading state (only before the first catalog): `NSProgressIndicator`
  spinning style, 32 points, centered, with "Loading catalog..." beneath in
  13 pt gray.

### Detail page (`AGDetailViewController`)

Content in an `NSScrollView` (vertical), all widths relative to the page
width `W`, side margins 32 points, maximum content width 760 points centered
when `W` is wider.

Top to bottom:

1. Header row: icon 128 x 128 at the left (placeholder when nil); to its
   right with 24 points gap: name in 26 pt bold, then author names joined by
   ", " as clickable links in 13 pt accent color (each opens `author.url`),
   then a 11 pt gray line "Category  ·  License" where License is
   `AGLicenseFormatter`'s string and is a link when there is a license URL;
   then 16 points; then the `AGInstallButton` at 120 x 28 (the big variant)
   and, right of it with 12 points gap, a plain-text link button "View on
   appimage.github.io".
2. 32 points gap, then the screenshot in an `AGScreenshotView`: full content
   width, height = width * 9/16 capped at 420, letterboxed on a
   `[NSColor colorWithCalibratedWhite:0.95 alpha:1.0]` background with
   radius 10 and the same 1-point border as cards. While loading, a centered
   small spinner. If there is no screenshot URL, the view is not added at all
   (the description moves up). If loading fails, the view shows "Screenshot
   unavailable" in gray, no placeholder art.
3. 24 points gap, then "Description" as a 15 pt bold heading, 8 points, then
   the description in a read-only, non-editable but
   selectable `NSTextView` (users copy text), 13 pt, line height 1.3, gray
   `[NSColor textColor]`, transparent background, height fitted to content
   (`sizeToFit` after `setString:` with the container width fixed). Paragraph
   breaks from `\n\n` are kept; single `\n` inside a paragraph is kept as is.
   When there is no description: "The publisher did not provide a
   description." in gray italic.
4. 24 points gap, then "Information" heading and a two-column key/value
   list, 13 pt, keys gray right-aligned in a 140-point column: "Developer",
   "Category" (all display names joined by ", "), "License", "Source"
   (GitHub link, `owner/repo` as the text), "Download page" (the
   downloadPageURL host as text, clickable), "Self-contained" (Yes/No, only
   when present), "Requires glibc" (only when present). Rows with nil values
   are omitted. Links open with `[[NSWorkspace sharedWorkspace] openURL:]`.
5. 32 points bottom margin.

The page recomputes its layout in `viewDidLayout`/`setFrameSize:` of its
view (see `gnustep-code-built-ui` on overriding both `setFrame:` and
`setFrameSize:` in the layout owner). Text does not reflow while dragging
faster than the run loop delivers; that is acceptable.

### AGInstallButton

One `NSView` subclass (not an `NSButton` subclass; the progress state is not a
button). Two sizes: small (80 x 22, 11 pt bold) for cards, large (120 x 28,
13 pt bold) for the detail page. States, each with a title and a behavior:

| State | Title | Look | Click |
| --- | --- | --- | --- |
| Get | "Get" | Pill (radius = height/2), accent-colored fill, white text | `installApp:` |
| Waiting | "Waiting..." | Pill, gray fill, white text | cancel task |
| Downloading | none | Pill outline, inner horizontal progress bar (determinate or barber pole) filling the pill, small "x" at the right to cancel | cancel task |
| Installed | "Open" | Pill outline in accent color, accent text | `launchApp:` |
| Failed | "Failed" | Pill, red outline and red text, tooltip = error | `NSAlert` with error and "Try Again" |
| OpenPage | "Open Page" | Pill outline gray, dark text | `openURL:downloadPageURL` |
| Unavailable | "Unavailable" | Gray text, no pill, disabled | nothing |

The button is told its `AGApp` and observes `AGInstaller`'s notifications for
that app (filter by `app.name`) to update itself. The barber pole is
animated with an `NSTimer` at 20 fps that exists only while a Downloading
button is on screen (`viewDidMoveToWindow` starts it when `window != nil`,
stops it when nil), so hidden cards cost nothing.

### Placeholder icon (`AGPlaceholderIcon`)

Draw in code: a 96-point rounded square (radius 22) filled with a vertical
gradient from `[NSColor colorWithCalibratedWhite:0.92 alpha:1.0]` to
`[NSColor colorWithCalibratedWhite:0.84 alpha:1.0]`, 1-point border at 8
percent black, and the first letter of the display name centered in 40 pt
bold white with a 1-point 15-percent-black shadow offset (0, -1). Cache one
`NSImage` per letter per size in an `NSCache`. This is deliberately better
than a generic gear icon: a grid of 200 apps without icons stays readable.

### Colors

Use theme colors: `windowBackgroundColor`, `controlBackgroundColor`,
`textColor`, `disabledControlTextColor` (for gray text), `gridColor`,
`selectedControlColor` (accent). The three literal colors in this section
(card border, screenshot letterbox, banner) are the only literals allowed and
live in one place, `AGColors.h` as static inline functions.

---------------------------------------------------------------------------

## 10. Menus and keyboard

Build the main menu in `AGAppDelegate` in code (`NSMenu`), GNUstep style: the
app menu carries the app name, and the whole menu appears in the desktop's
global menu bar. Items and key equivalents:

    AppGarden
      About AppGarden
      -
      Hide AppGarden        Cmd-H
      Hide Others           Cmd-Alt-H
      Show All
      -
      Quit AppGarden        Cmd-Q
    File
      Close Window          Cmd-W
    Edit
      Cut  Cmd-X, Copy  Cmd-C, Paste  Cmd-V, Select All  Cmd-A   (standard actions, for the search field)
      -
      Find                  Cmd-F     -> focuses the search field
    View
      Discover              Cmd-1
      Installed             Cmd-2
      -
      Reload Catalog        Cmd-R     -> reloadIgnoringCache
    Go
      Back                  Cmd-[     (Cmd-LeftBracket; also Escape in the content area pops when the stack is deeper than 1)
    Window
      Minimize              Cmd-M
      -
      AppGarden             (the window list is managed by NSApp's windowsMenu)
    Help
      AppGarden Help        (opens https://github.com/gershwin-desktop/gershwin-components/tree/dev/AppGarden with openURL:)

Every menu item has a target and action and is validated with
`validateMenuItem:` (Back disabled when nothing to pop, Reload disabled while
loading). Verify with DriveUI that `assert menu item "AppGarden/Quit
AppGarden" shortcut "Cmd+Q"` passes, as in `stickies.uitest`.

---------------------------------------------------------------------------

## 11. Preferences (user defaults)

No preferences window. Read (never write back) these defaults in the domain
of the app:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `AGFeedURL` | string | `https://appimage.github.io/feed.json` | Catalog location, for testing. |
| `AGCacheMaxAgeHours` | number | 6 | Section 6 step 1. |
| `AGShowToolkitCategories` | bool | NO | Show Qt/GTK/GNOME/Application in the sidebar. |

Read the `gnustep-app-preferences` skill for why the app must not write
defaults it does not own and how to re-read on
`NSUserDefaultsDidChangeNotification` (apply `AGShowToolkitCategories`
live; the other two on next load).

---------------------------------------------------------------------------

## 12. Build files: GNUmakefile, Info.plist, icon

### GNUmakefile

Model it on `SoftwareUpdate/GNUmakefile`:

    include $(GNUSTEP_MAKEFILES)/common.make
    GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

    APP_NAME = AppGarden
    PACKAGE_NAME = AppGarden
    AppGarden_PRINCIPAL_CLASS = NSApplication
    AppGarden_APPLICATION_ICON = AppGarden.png
    AppGarden_OBJC_FILES = main.m Models/*.m Services/*.m Controllers/*.m Views/*.m   (list every file explicitly, no wildcards)
    AppGarden_RESOURCE_FILES = Resources/AppGarden.png Resources/AppGarden@2x.png
    AppGarden_LOCALIZED_RESOURCE_FILES = Localizable.strings
    AppGarden_LANGUAGES = English
    ADDITIONAL_OBJCFLAGS += -IModels -IServices -IControllers -IViews
    ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions -Wall -Wextra -Wno-unused-parameter
    ADDITIONAL_OBJCFLAGS += -I/System/Library/Headers
    ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
    ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1
    include $(GNUSTEP_MAKEFILES)/application.make

Check whether `SoftwareUpdate`'s `-ldispatch` is needed by the framework
link on this system (`ldd` the built binary; if `libPackageManager` pulls
libdispatch it links transitively and you do not add it). No
`GNUmakefile.in` exists for this component, so nothing else to keep in sync.

Because AppGarden links `PackageManager.framework`, add `AppGarden` to the
`LIBRARY_CONSUMERS` filter list in the top-level `GNUmakefile` (the line
`LIBRARY_CONSUMERS := $(filter Menu Network Sound ... ,$(SUBDIRS))`) and to
the matching sentence in `AGENTS.md` ("library consumers (Build Menu Network
Sound Whisper)"). Tell the Battery peer session about this edit (section 1).

Build: `cd AppGarden && gmake`. Install: `cd AppGarden && sudo gmake install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM`,
then `ls /Local/Applications /Local/Library/Frameworks` must not show
anything of ours.

### AppGardenInfo.plist

Copy `Stickies/StickiesInfo.plist`, change every value. `CFBundleIdentifier`
`io.github.gershwin-desktop.AppGarden`, `ApplicationDescription`
"Discover and install applications for your desktop" (function only; never
name AppImage's website, GNUstep or any platform here), `Authors` Simon
Peter, `URL` the repository, `NSHumanReadableCopyright` and
`CopyrightDescription` as in Stickies, `CFBundleIconFile AppGarden.png`,
version 0.1. Check the `gnustep-info-plist` skill for the About panel keys.

### Icon

Create `Resources/AppGarden.svg` (source, committed) and render
`AppGarden.png` (512 x 512) and `AppGarden@2x.png` (1024 x 1024) with
ImageMagick `convert -background none -resize 512x512! AppGarden.svg AppGarden.png`,
the way Menu renders its icons. Design: a rounded square (radius 22 percent)
with a soft green-to-teal vertical gradient, a white stylized sprout with two
leaves growing out of a flat white pot line at the bottom third, 6 percent
black inner border. Keep it to 5 or 6 SVG paths; no text; no drop shadow.
Look at `Stickies/Stickies.png` and `Books/Books.png` for the level of
detail that fits this desktop's Dock.

---------------------------------------------------------------------------

## 13. Tests

Test-first for the Foundation layer, following the `gnustep-red-green-tdd`
skill exactly (PASS macros, `TestInfo` marker, `GNUmakefile.preamble` for
collaborators, the committed generated `GNUmakefile`). Directory
`AppGarden/Tests/Unit/`. Each tool links the model sources it needs as
collaborators, like `Stickies/Tests/Unit/GNUmakefile.preamble`.

Tools and what they must assert (minimum):

`t_AGFeedParser` (input: `../../Fixtures/feed-sample.json`)
- 15 apps parsed; `appNamed:@"4KWALL"` exists; count of skipped items 0.
- `Apache_NetBeans`.displayName == "Apache NetBeans".
- `86Box`.summary nil, descriptionText nil, license nil.
- `Addaps`: links empty, iconURL nil, downloadPageURL nil, githubRepo nil.
- `DDCal`.categories == @[] (null dropped) and it is still listed.
- `BlackMirror`.downloadPageURL == the Install link.
- `QOwnNotes`.iconURL nil (svg), downloadPageURL ends with `.mirrorlist`, githubRepo nil.
- `4KWALL`.iconURL absoluteString == "https://appimage.github.io/database/4KWALL/icons/512x512/com.warlordsoftwares.wallpaper-app-4kwall.png"; screenshotURL likewise; githubRepo "rishabh3354/4KWALL"; githubURL "https://github.com/rishabh3354/4KWALL"; catalogPageURL "https://appimage.github.io/4KWALL/".
- `OVideo`.selfContained YES; `APK_Editor_Studio`.glibcRequired "2.30".
- `Alpine_Client`.authors empty.
- `Artifact`.summary length <= 90 and ends with the ellipsis.
- `apps` sorted case-insensitively by displayName (`lux` is not last).
- A synthetic item with Download `https://github.com/a/b/releases` and no GitHub link yields githubRepo "a/b".
- Error cases: `[NSData data]` -> error; `{"items": 5}` -> error; `{"items": [1, {"name": "x"}, {"noname": 1}]}` -> one app, two skipped.

`t_AGDownloadResolver`
- 4KWALL -> GitHubLatestRelease "rishabh3354/4KWALL".
- QOwnNotes on x86_64 -> DirectURL ".../QOwnNotes-latest-x86_64.AppImage"; on aarch64 -> WebPageOnly.
- lux -> WebPageOnly; Addaps -> None; BlackMirror -> GitHubLatestRelease.

`t_AGSearchIndex`
- query "netbeans" finds Apache_NetBeans first; "NETBEANS" too; "apk editor" finds APK_Editor_Studio; "wallpaper" finds 4KWALL via description; "" in category "Game" returns the games in catalog order; "zzzz" returns empty.

`t_AGCategoryNames` and `t_AGLicenseFormatter`
- The mappings of section 5, including hidden toolkit categories and unknown categories sorted after known ones.

`t_AGGridLayout`
- width 1000 with 200-wide cards, gap 20, inset 24 -> 4 columns (5 would need 24+5*200+4*20+24 = 1128), gaps widened to spread; frame of index 5 is in row 1 column 1; `indexAtPoint:` in a gap returns -1; heightForCount 0 == 0; heightForCount 1 == inset + 232 + inset.

`t_AGInstallRegistry`
- Uses a temporary directory (set via an init parameter), round-trips one entry, drops an entry whose file does not exist on `reconcile`.

`t_AGDiscoverOrder`
- `nil` in gives an empty list out, never nil; an empty list stays empty; a single app stays itself.
- 500 apps in, 500 out, and the multiset is unchanged (counted, so a lost or duplicated app fails).
- The order is actually random, which a rotation or a sort with a fixed key would fail: the first and the last entry of 40 shuffles of a 40-entry list each vary, and two apps swap within 40 shuffles.
- Two shuffles of the same 500 apps are not equal, so the order differs between launches.
- The caller's array is left in its own order.

`t_AGFeedLoader`
- Runs against `file://` URLs? `curl` supports `file://`, so point `AGFeedURL` at the fixture through a temporary cache dir: first load fetches (fromCache NO), second load within max age does not touch the network (assert by pointing the URL at a nonexistent file the second time: it must still succeed from cache). A broken JSON at the URL with a good cache: completion gets the cached catalog AND an error.

The rules that choose which file of a release to download are not tested
here: they live in the framework, and are covered by
`PackageManager/Tests/AGAppImageAssetPickerTests.m` - 18 cases over real
releases from the live catalog, `#include`d into
`PackageManager/Tests/PackageManagerTest.m` rather than listed in its
`OBJC_FILES` (the `TAssert` macros expand to a `return NO`, so the cases have
to be compiled into a file that owns the runner). Run them with
`cd PackageManager && gmake test`.


Run all with `gnustep-tests AppGarden/Tests/Unit` (not the binaries alone),
report the PASS/FAIL counts. Every test must pass before the UI work starts.

`Tests/appgarden.uitest` (DriveUI, run in an isolated uitest slot):
- launch, wait for window "AppGarden", assert menu items and shortcuts
  (Quit Cmd+Q, Find Cmd+F, Reload Catalog Cmd+R), type "netbeans" into the
  search field, assert a card titled "Apache NetBeans" exists in the tree,
  press Escape, quit with Cmd+Q. Point `AGFeedURL` at the fixture via the
  test user's defaults so the test does not need the network.


  No assertion may name a card that Discover happens to show first: Discover
  is shuffled, so no name is ever in a known place. After Escape the test
  counts `AGAppCardView` rows in the tree through `drive_ui` and requires more
  than one, which is exactly what the filtered page denied and does not depend
  on the order. The uitest language has no widget-count verb, so this is a
  `shell` step whose exit status carries the result. Two traps in that step, both
  found by running a version with the threshold raised so it had to fail: a
  double quote inside the string truncates the command to `test \`, which
  passes for any grid (the parser takes the first `"..."` and does not
  understand a backslash before its closing quote), and the pid must be looked
  up under `pgrep -u $(id -un)`, because a bare process name finds another
  account's AppGarden first and the count then reads 0 on every run. Verify
  any change to that step by raising the threshold and watching it fail.

---------------------------------------------------------------------------

## 14. Acceptance checklist

Do not report done until every line is true and you have the evidence.

- [ ] `gmake clean && gmake` in `AppGarden/` prints zero warnings.
- [ ] `gnustep-tests AppGarden/Tests/Unit` reports all PASS, no FAIL, no
      "No tests found".
- [ ] Installed to SYSTEM only; `/Local` untouched (show the `ls`).
- [ ] Cold start with no cache: spinner, then grid within a few seconds on
      a normal connection; second start shows the grid immediately from
      cache (measure with a stopwatch or DriveUI timing and state it).
- [ ] Scrolling the full Discover grid (1500+ cards) is smooth; process
      memory stays under 150 MB after scrolling to the end (`ps -o rss`).
- [ ] Search filters on each keystroke without lag.
- [ ] Discover is not in alphabetical order, its order is stable while the
      user browses and searches it, and it differs between two launches.
      Category and Downloaded pages are alphabetical.
- [ ] The top bar holds only the back arrow and the search field: no page
      title between them, and the arrow is an icon with the tooltip "Back"
      that is hidden on the root page. Screenshot the bar on a detail page.
- [ ] Discover is not in alphabetical order, its order is stable while the
      user browses and searches it, and it differs between two launches.
      Category and Downloaded pages are alphabetical.
- [ ] The top bar holds only the back arrow and the search field: no page
      title between them, and the arrow is an icon with the tooltip "Back"
      that is hidden on the root page. Screenshot the bar on a detail page.

- [ ] Every sidebar category shows its count and its apps.
- [ ] Detail page for `4KWALL`: icon, author link, "Proprietary" license as
      a link, screenshot, description, information rows, "View on
      appimage.github.io" opens the browser.
- [ ] Detail page for `86Box`: "The publisher did not provide a
      description." and "Unknown license". Detail page for `Addaps`:
      placeholder icon with "A", no screenshot view, button "Unavailable".
- [ ] Get on a small app (`DDCal` or another small GitHub-released one)
      downloads, the button shows progress then "Open", "Open" starts the app
- [ ] Get on an app whose newest release holds no AppImage (Obsidian's newest
      is a mobile-only `.apk`) installs from the release that has one; Get on
      a release holding AppImages of several programs (AppImageUpdate) picks
      the file matching the catalog's name for the app; Get on a renamed
      repository (ipfs-desktop) works rather than reporting a lookup failure.
      Each of these was broken before the release-resolution rewrite.
      (verify a window appears in the isolated session with DriveUI), the
      file exists at the path from `launcherPathForAppName:`, `make_services`
      lists it, the Downloaded page lists it, Remove asks and deletes it.
- [ ] Get on an app whose newest release holds no AppImage (Obsidian's newest
      is a mobile-only `.apk`) installs from the release that has one; Get on
      a release holding AppImages of several programs (AppImageUpdate) picks
      the file matching the catalog's name for the app; Get on a renamed
      repository (ipfs-desktop) works rather than reporting a lookup failure.
      Each of these was broken before the release-resolution rewrite.
      (verify a window appears in the isolated session with DriveUI), the
      file exists at the path from `launcherPathForAppName:`, `make_services`
      lists it, the Downloaded page lists it, Remove asks and deletes it.
- [ ] Unplug the network (or set `AGFeedURL` to an unreachable host) with a
      cache present: banner with error and Retry, catalog still browsable.
      Without cache: error view with Retry.
- [ ] `QOwnNotes` shows Get and installs from the openSUSE URL on x86_64.
- [ ] `lux` shows "Open Page" and opens the Bitbucket page.
- [ ] Window resize from 760 to 1600 wide relayouts the grid columns and the
      detail page without overlaps or clipped text (DriveUI geometry check
      or screenshots in the isolated session).
- [ ] The `.uitest` passes in an isolated slot.
- [ ] `git status` shows only `AppGarden/`, the top-level `GNUmakefile` line
      and the `AGENTS.md` sentence. Nothing else staged.
- [ ] The user has tested on their desktop and said it works.

---------------------------------------------------------------------------

## 15. Things not to do

- Do not use `NSCollectionView`. This repo has no working example of it
  under the Eau theme and the recycled custom grid is under 400 lines.
- Do not use `NSURLSession`, `NSURLConnection`, `dispatch_*`, threads via
  `NSThread` directly. `NSOperationQueue` + `curl` only.
- Do not add a dependency (no JSON library, no HTTP library, no image
  library). Foundation, AppKit, PackageManager.framework, curl.
- Do not call the GitHub API while browsing, and do not fetch icons,
  screenshots or text from anywhere but `https://appimage.github.io/`
  (rate limits: GitHub Pages has none that matter, `api.github.com` allows
  60 anonymous requests per hour, `raw.githubusercontent.com` throttles).
  The downloader's own lookup stays off `api.github.com` for the same reason:
  that anonymous quota is what once made every Get fail with 403 for the rest
  of the hour.
  The downloader's own lookup stays off `api.github.com` for the same reason:
  that anonymous quota is what once made every Get fail with 403 for the rest
  of the hour.
- Do not write to `~/Applications`, `~/.local`, `/usr`, `~/Downloads`, or
  create `.desktop` files or symlinks. One file at the path the framework
  gives you, plus the registry plist and the cache directory.
- Do not fetch icons for items that are not visible.
- Do not hide errors. Do not add "fallback" code paths this brief did not
  name.
- Do not touch `PackageManager/` or `make_services/`; if you need a change
  there, stop and ask the user with a proposal.
- Do not install to LOCAL, do not commit, do not push, unless told.
- Do not put version numbers, "beta", "AppImageHub", "Mac", "GNUstep" in
  user-visible text.

---------------------------------------------------------------------------

## 16. Handing over

When everything in section 14 is true:

1. Replace `AppGarden/README.md` with a user-facing README (what it is, a
   screenshot from the isolated session saved as `Resources/screenshot.png`
   is welcome but optional, how to build, how to test).
2. Keep `INSTRUCTIONS.md` and `FEED.md` in the directory as the design
   record; update `FEED.md` if the live data taught you something new, and
   `DOWNLOADS.md` if the download resolution changed.
3. Tell the user, in keywords: what was built, the test counts, the install
   location, the `make_services` finding from section 8, anything you left
   out and why, and the one-line `LIBRARY_CONSUMERS` change. Ask whether to
   commit. Do not commit before that answer.
4. If you learned something reusable (for example how the recycled grid or
   the `curl -z` cache behaves in this stack), ask the user whether a skill
   should be written for it.

---------------------------------------------------------------------------

## 14. Acceptance checklist

Do not report done until every line is true and you have the evidence.

- [ ] `gmake clean && gmake` in `AppGarden/` prints zero warnings.
- [ ] `gnustep-tests AppGarden/Tests/Unit` reports all PASS, no FAIL, no
      "No tests found".
- [ ] Installed to SYSTEM only; `/Local` untouched (show the `ls`).
- [ ] Cold start with no cache: spinner, then grid within a few seconds on
      a normal connection; second start shows the grid immediately from
      cache (measure with a stopwatch or DriveUI timing and state it).
- [ ] Scrolling the full Discover grid (1500+ cards) is smooth; process
      memory stays under 150 MB after scrolling to the end (`ps -o rss`).
- [ ] Search filters on each keystroke without lag.
- [ ] Every sidebar category shows its count and its apps.
- [ ] Detail page for `4KWALL`: icon, author link, "Proprietary" license as
      a link, screenshot, description, information rows, "View on
      appimage.github.io" opens the browser.
- [ ] Detail page for `86Box`: "The publisher did not provide a
      description." and "Unknown license". Detail page for `Addaps`:
      placeholder icon with "A", no screenshot view, button "Unavailable".
- [ ] Get on a small app (`DDCal` or another small GitHub-released one)
      downloads, the button shows progress then "Open", "Open" starts the app
      (verify a window appears in the isolated session with DriveUI), the
      file exists at the path from `launcherPathForAppName:`, `make_services`
      lists it, the Installed page lists it, Remove asks and deletes it.
- [ ] Unplug the network (or set `AGFeedURL` to an unreachable host) with a
      cache present: banner with error and Retry, catalog still browsable.
      Without cache: error view with Retry.
- [ ] `QOwnNotes` shows Get and installs from the openSUSE URL on x86_64.
- [ ] `lux` shows "Open Page" and opens the Bitbucket page.
- [ ] Window resize from 760 to 1600 wide relayouts the grid columns and the
      detail page without overlaps or clipped text (DriveUI geometry check
      or screenshots in the isolated session).
- [ ] The `.uitest` passes in an isolated slot.
- [ ] `git status` shows only `AppGarden/`, the top-level `GNUmakefile` line
      and the `AGENTS.md` sentence. Nothing else staged.
- [ ] The user has tested on their desktop and said it works.

---------------------------------------------------------------------------

## 15. Things not to do

- Do not use `NSCollectionView`. This repo has no working example of it
  under the Eau theme and the recycled custom grid is under 400 lines.
- Do not use `NSURLSession`, `NSURLConnection`, `dispatch_*`, threads via
  `NSThread` directly. `NSOperationQueue` + `curl` only.
- Do not add a dependency (no JSON library, no HTTP library, no image
  library). Foundation, AppKit, PackageManager.framework, curl.
- Do not call the GitHub API while browsing, and do not fetch icons,
  screenshots or text from anywhere but `https://appimage.github.io/`
  (rate limits: GitHub Pages has none that matter, `api.github.com` allows
  60 anonymous requests per hour, `raw.githubusercontent.com` throttles).
- Do not write to `~/Applications`, `~/.local`, `/usr`, `~/Downloads`, or
  create `.desktop` files or symlinks. One file at the path the framework
  gives you, plus the registry plist and the cache directory.
- Do not fetch icons for items that are not visible.
- Do not hide errors. Do not add "fallback" code paths this brief did not
  name.
- Do not touch `PackageManager/` or `make_services/`; if you need a change
  there, stop and ask the user with a proposal.
- Do not install to LOCAL, do not commit, do not push, unless told.
- Do not put version numbers, "beta", "AppImageHub", "Mac", "GNUstep" in
  user-visible text.

---------------------------------------------------------------------------

## 16. Handing over

When everything in section 14 is true:

1. Replace `AppGarden/README.md` with a user-facing README (what it is, a
   screenshot from the isolated session saved as `Resources/screenshot.png`
   is welcome but optional, how to build, how to test).
2. Keep `INSTRUCTIONS.md` and `FEED.md` in the directory as the design
   record; update `FEED.md` if the live data taught you something new, and
   `DOWNLOADS.md` if the download resolution changed.
3. Tell the user, in keywords: what was built, the test counts, the install
   location, the `make_services` finding from section 8, anything you left
   out and why, and the one-line `LIBRARY_CONSUMERS` change. Ask whether to
   commit. Do not commit before that answer.
4. If you learned something reusable (for example how the recycled grid or
   the `curl -z` cache behaves in this stack), ask the user whether a skill
   should be written for it.
