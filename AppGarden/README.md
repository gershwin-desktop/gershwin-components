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
  the button shows its progress; afterwards it reads Open.
- Downloaded lists what AppGarden downloaded. The detail page of a downloaded
  application has a Remove button that deletes the file after asking.
- Applications the catalog only links to a web page for show Open Page.

`INSTRUCTIONS.md` is the brief the application was built from, `FEED.md`
documents the feed's shape and every irregularity the parser survives, and
`DOWNLOADS.md` documents how a Get works out which file to fetch.
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
registry, install task):

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
documents the feed's shape and every irregularity the parser survives, and
`DOWNLOADS.md` documents how a Get works out which release and which file to
fetch. `Fixtures/feed-sample.json` holds 15 real entries covering all of
them.
