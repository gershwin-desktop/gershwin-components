# AppGarden

AppGarden is the app store of the Gershwin desktop. It browses the AppImage
catalog published at https://appimage.github.io/feed.json, shows every
application with its icon, screenshot, description, author and license, and
downloads an application with one click so that it lands in the user's
Applications folder and starts like any other application.

## Using it

- Discover lists the whole catalog in a random order, and keeps that order
  while you browse and search it. The sidebar groups the catalog by category;
  a category page and Downloaded stay in alphabetical order.
- Get works out which release of a project to use and which file inside it to
  download. `DOWNLOADS.md` documents that, the rules it follows, and what was
  wrong with it before.
- Typing in the search field filters the current scope as you type.
- A card opens the detail page: big icon, author and license links, the
  screenshot, the full description and an information table. The back arrow at
  the top left returns.
- Get downloads the application. For a GitHub project the newest release that
  actually has an AppImage for this machine is used, and within it the file
  matching this machine's CPU and the catalog's name for the app; direct
  .AppImage links download as they are. If a release holds several AppImages
  and none is clearly the right one, the button reads Failed and the alert
  names the files rather than picking one at random. While the download runs
  the button shows its progress; afterwards it reads Show, which shows the file in the file manager.
- Some software is high risk by its category alone, so Get opens a panel
  first when a word of one of those categories appears in an item's title,
  description or other metadata. `RISKS.md` documents the categories, the
  keywords and how to edit them. Cancel is the default button, so Return and
  Escape both mean "do not download". The panel gives one sentence per
  category, and the button reads Download at Your Own Risk.
- The detail page of an app that comes from GitHub, by its feed entry or by a
  direct link on github.com, shows the star count of its
  repository, read from the repository's web page (the API allows only 60
  anonymous requests an hour). The same page also feeds the risk check: for an
  app hosted on GitHub, Get reads the repository's description and README as
  well as the catalog entry, so software that calls itself an AI workspace is
  flagged even when its catalog line says nothing. The page is cached for six
  hours, so Get is instant once the detail page has been open.
- When the catalog entry has no license, the detail page asks GitHub for the
  repository's license, the one thing read from the API. A repository costs
  one of the 60 anonymous requests an hour once: the answer is kept for a
  week and then revalidated with its ETag, which GitHub does not count when
  nothing changed. After a refusal the question is not asked again for an
  hour.
- Downloaded lists what AppGarden downloaded. The detail page of a downloaded
  application has a Remove button that deletes the file after asking.
- Applications the catalog only links to a web page for show Open Page.

`INSTRUCTIONS.md` is the brief the application was built from, `FEED.md`
documents the feed's shape and every irregularity the parser survives,
`DOWNLOADS.md` documents how a Get works out which file to fetch, and
`RISKS.md` documents the risk keywords a Get checks first.
`Fixtures/feed-sample.json` holds 15 real entries covering all of them.
`~/Library/Caches/io.github.gershwin-desktop.AppGarden/` for six hours, so a
second launch shows the grid at once. When the catalog cannot be fetched, the
cached one stays browsable behind a banner with a Retry button.

Defaults (read only, never written back):

| Key | Default | Meaning |
| --- | --- | --- |
| `AGFeedURL` | the live feed | Catalog location, for testing against a local file. |
| `AGCacheMaxAgeHours` | 6 | How long a cached catalog is used without a fetch. |
| `AGShowToolkitCategories` | NO | Also list Qt, GTK, GNOME and Application in the sidebar. |

The defaults domain is the bundle identifier,
`io.github.gershwin-desktop.AppGarden`, and this defaults tool wants plain
values (`defaults write io.github.gershwin-desktop.AppGarden AGFeedURL
file:///path/feed.json`, no `-string`).

## Building

    cd AppGarden && gmake
    sudo gmake install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM

The application links the `PackageManager` framework, so the top-level
`gmake install` builds it after the framework. It needs `curl` at run time.

## Testing

Unit tests for the Foundation layer (parser, categories, licenses, search,
download resolution, grid geometry, Discover order, feed loader, install
registry, install task, risk keywords):

    gnustep-tests AppGarden/Tests/Unit

The rules that choose which file of a GitHub release to download live in the
framework rather than here, and are tested with it:

    cd PackageManager && gmake test

That runs `PackageManagerTest`, which covers the asset picker against real
releases from the live catalog.

The DriveUI smoke test runs against the bundled fixture in an isolated
uitest slot after the application has been installed:

    run_uitest AppGarden/Tests/appgarden.uitest

## Design record

`INSTRUCTIONS.md` is the brief the application was built from, `FEED.md`
documents the feed's shape and every irregularity the parser survives,
`DOWNLOADS.md` documents how a Get works out which release and which file to
fetch, and `RISKS.md` documents the risk categories and the keywords that
raise the panel. `Fixtures/feed-sample.json` holds 15 real entries covering
all of them, `Fixtures/feed-risk.json` three invented ones for the panel.
