download.kde.org directory indexes, recorded 2026-09-28
==========================================================

These are real pages, saved exactly as `curl` wrote them, and they are the
input to the index-parsing cases in `GWKDEAppImagePickerTests.m`. A parser
tested against a hand-written sample proves only that the sample parses; these
prove the real page does, including the parts that are not files at all: the
KDE footer links out to kde.org, the column sort links (`?C=N;O=D`), the
"Parent Directory" row that marks a page as an index, and the two `href`
attributes a *non*-index page happens to have.

| file | what it is | what it is for |
|------|------------|----------------|
| `digikam-listing.html` | `https://download.kde.org/stable/digikam/` | the reported case: one version directory, `9.1.0` |
| `digikam-9.1.0-listing.html` | `.../digikam/9.1.0/` | four AppImages of one program, Qt5 and Qt6, release and `-debug` |
| `krita-listing.html` | `https://download.kde.org/stable/krita/` | seven releases plus `FastSketchPlugin-*` and `updates`, which are not versions, and `6.0.2.1` listed before `6.0.2` |
| `labplot-listing.html` | `https://download.kde.org/stable/labplot/` | no version directory at all: an AppImage, `.dmg`s, an `.exe` and source tarballs side by side |
| `not-a-listing.html` | `https://apps.kde.org/digikam` | an ordinary application page, which must be refused rather than parsed |

To refresh one:

    curl -fsSL https://download.kde.org/stable/digikam/ -o digikam-listing.html

Keep them as they are served. The tests assert specific file names out of
them, so a refresh that renames a build is a real change in what the site
offers and the assertions should be revisited, not edited to match.
