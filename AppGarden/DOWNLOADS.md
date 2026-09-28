# Resolving a download

How AppGarden decides *which file* to fetch when a user presses Get. Two
decisions, in this order:

1. **Which release** of a project's GitHub repository to look at.
2. **Which file** inside that release to download.

Both live in `PackageManager`, not here. AppGarden supplies two strings - the
repository (`AGDownloadResolver`) and the app's catalog name
(`AGInstaller`) - and the downloader does the rest. The rules are a
transliteration of the catalog's own selection script,
[`code/find-appimage.sh`](https://github.com/AppImage/appimage.github.io), so
that "the AppImage of this release" means the same thing in the app as on
appimage.github.io. Do not copy any of it into AppGarden; a difference between
the app and the website is a bug in one of them, not a feature.

| Stage | Where |
| --- | --- |
| `AGDownloadResolver` (where from) | `AppGarden/Models/AGDownloadResolver.m` |
| Which release | `PackageManager/GWAppImageDownloader.m`, `+preferredTagForRepo:progress:` |
| Which file | `PackageManager/GWAppImageAssetPicker.m` |

## No API, ever

The lookup reads github.com's own web pages - `releases/latest` as a redirect
chain, `releases.atom`, `releases/expanded_assets/<tag>` - and never
`api.github.com`. The API's 60 anonymous requests per hour are what once made
every Get fail with 403 for the rest of the hour on a desktop that had already
used them up.

A Get costs **2 requests** when the newest non-pre-release already holds an
AppImage, and up to **8** when it has to walk back (1 redirect probe + 1 Atom
feed + 6 asset pages). Browsing the catalog costs none.

## Which release

`+preferredTagForRepo:progress:` picks:

> the newest release that is **neither a draft nor a pre-release and does hold
> an AppImage**; failing that, the newest that holds one, pre-release or not.

Both halves are load-bearing on real projects:

- A release merely *existing* is not enough. Obsidian's newest release
  (`v1.13.8`) is a mobile-only release holding a single `.apk`; `v1.13.7` has
  two AppImages.
- A pre-release is only accepted when there is nothing else. qTox publishes
  nothing but pre-releases, so `releases/latest` lands on the list page and
  names no tag at all.

Supporting details:

- **The walk-back reads at most 6 entries** of `releases.atom`
  (`kGWMaxReleasesToWalk`). A project that has stopped shipping AppImages in
  its last six releases is not helped by a seventh request.
- **The tag comes from each Atom entry's own `href=".../releases/tag/TAG"`,
  never from its `<title>`.** The two disagree in both directions: Obsidian
  titles `v1.13.7` "1.13.7" with no `v`, AppFlowy titles `0.14.5` "v0.14.5"
  with one.
- **Redirects are followed with `-L` on every request**, and the
  `releases/latest` probe keeps the *last* `location:` carrying
  `/releases/tag/`.
- A tag containing a slash is percent-encoded before it goes into the path
  (janhq/jan's `checkpoint/code-ui-...`).

### Why `-L` matters: renamed repositories

`ipfs-shipyard/ipfs-desktop` was renamed to `ipfs/ipfs-desktop`. A renamed
repository answers **301**, and the first `Location:` of a renamed one still
ends in `/releases/latest` and names **no tag**:

    301  location: https://github.com/ipfs/ipfs-desktop/releases/latest
    302  location: https://github.com/ipfs/ipfs-desktop/releases/tag/v0.50.1

Reading only the first header is how "GitHub release lookup failed" came up
for an app that downloads perfectly well. Two of the eleven repositories
measured on 2026-09-28 were renamed.

## Which file

`GWAppImageAssetPicker` takes the asset names of **one** release and returns
one name. It is Foundation-only and does no network, which is what lets the
rules be tested against real release names instead of invented ones.

Five rules, in order. **Each is a no-op unless it keeps some but not all of
the candidates.** That guard is what stops any single rule from emptying the
field, and it is why an arm-only release passes through "prefer x86-64"
untouched.

| # | Rule | Why it exists |
| --- | --- | --- |
| 1 | keep only names **ending** in `.appimage`, case-insensitive | A checksum, `.zsync` or `.blockmap` file *contains* ".AppImage". AppImageUpdate's release has 12 zsyncs, ~150 KB each. digiKam's real file is lower case: `digikam-5.9.0-01-x86-64.appimage`. |
| 2 | drop the **other architectures**, on word boundaries | **The rule that does most of the work.** A release that also ships an arm build puts it first, and often uploads it first. |
| 3 | prefer the **x86-64 spellings**: `x86_64`, `x86-64`, `amd64`, `x64`, `linux64`, `64bit` | The catalog uses six spellings; the old code knew two, so four fell through to "take the first AppImage". |
| 4 | drop `debug`, `dbg`, `test`, `nightly`, `symbols` - from the **asset name only** | qTox's entire repository is `qTox-nightly-releases` and its only usable AppImage is a nightly. A rule that looked at the repository, the tag or the URL would delete it from the catalog. |
| 5 | prefer the asset whose name **skeleton** equals the app name's skeleton | One release can hold AppImages of several different *programs*. |

Architecture matching is on **word boundaries**, so the "arm" in "Armour" and
the "64" in "macOS10" do not count. The list of dropped architectures is
`aarch64`, `arm64`, `armhf`, `armel`, `armv[0-9]l?`, `arm32`, `arm`,
`i[3-6]86`, `x86_32`, `ia32`, `x32`, `ppc64(le)?`, `s390x`, `riscv64`,
`loong(arch)?64`, `mips64(el)?`, `32-bit`.

### The skeleton

`+stemForAssetName:` reduces a name to a comparable form: lowercased, without
the `.appimage` extension, without a 7-to-40-digit hex git hash, without
`x86_64`/`x86-64`/`amd64`/`x64`/`linux64`/`linux`/`glibc`, and without any
digits. What is left that is a letter is the program's name.

| Input | Skeleton |
| --- | --- |
| `AppImageUpdate-x86_64.AppImage` | `appimageupdate` |
| `appimageupdatetool-x86_64.AppImage` | `appimageupdatetool` |
| `validate-x86_64.AppImage` | `validate` |
| `Obsidian-1.13.7.AppImage` | `obsidian` |
| `digikam-5.9.0-01-x86-64.appimage` | `digikam` |
| `qTox-c0e9a3b7…1993dc5f-x86_64.AppImage` | `qtox` |
| `4kWall-2026.9.5-x86_64.AppImage` | `kwall` |
| `4kWall-x86_64.AppImage` | `kwall` |
| `4KWALL` | `kwall` |
| `Game-Armour-x86_64.AppImage` | `gamearmour` (the "arm" in "Armour" is a letter, not a CPU) |

The git hash is why qTox is installable at all: its only AppImage carries a
40-character commit hash, and without stripping it the name could never be
compared with the app's own.

### Ties

- Several left with the **same** skeleton are taken in **name order**. 4KWALL
  ships `4kWall-2026.9.5-x86_64.AppImage` and `4kWall-x86_64.AppImage`, which
  are the same bytes with the same size, sha256 and upload time. **This is a
  deliberate deviation from the catalog**, which refuses here - refusing would
  break an app that demonstrably works. Name order picks the versioned one,
  which is also what the previous code picked.
- Several left with **different** skeletons report `GWAppImagePickAmbiguous`
  and are **not** guessed at, because either could be a different program. The
  candidates come back so the error can name them.

### Two upstream warts, kept on purpose

Both are asserted as-measured in the tests rather than quietly "fixed", and
both are harmless because rule 2 or 3 has already decided the release by the
time the skeleton is compared:

- `FreeCAD_1.1.3-Linux-x86_64-py311.AppImage` reduces to `freecadpy`, not
  `freecad`, so it never matches the catalog's `FreeCAD2`. The "py" of
  `py311` survives.
- `86Box-Linux-x86_64-b9001.AppImage` reduces to `boxb`, not `box`: the
  build number's leading "b" is left behind once the digits go.

The catalog's own `stem.sh` produces the same two results, which is how they
were confirmed rather than guessed.

## What the user is told

Three refusals, all from the framework and therefore English-only. The three
outcomes were confirmed by driving the installed picker:

| Situation | `GWAppImagePickOutcome` | Message |
| --- | --- | --- |
| no release has an AppImage at all | `NoAppImage` | `No release of <repo> has an AppImage` |
| the chosen release has AppImages but they cannot be told apart | `Ambiguous` | `The newest release of <repo> has several AppImages and none of them is clearly the right one for this machine: <the names>` |
| a release was found but nothing in it is for this machine | `NoAppImage` | `No release of <repo> has an AppImage for this machine` |

The middle one is the only case where the user may want to fetch a file by
hand, which is why it names the candidates rather than just saying "failed".
Plus the pre-existing transport failures: `Could not reach GitHub for
<repo>`, `GitHub release assets could not be read for <repo>`, `No release
assets found for <repo>`.

Note that `NoAppImage` covers two different situations - nothing anywhere, and
nothing for *this* machine - which is why there are two messages for it. The
picker itself cannot tell them apart; the downloader can, because it knows
which release it was looking at.

`AppGarden/Services/AGInstallTask.m` still prefixes "GitHub rate limit
reached: " when curl's own line shows a refusal, because a rate limit and a
network fault are otherwise indistinguishable.

## Tests

    cd PackageManager && gmake test

`PackageManager/Tests/AGAppImageAssetPickerTests.m` - 18 cases over real
releases from the live catalog, asset names copied from what the forge listed
on 2026-09-28. It is `#include`d into
`PackageManager/Tests/PackageManagerTest.m` rather than listed in
`OBJC_FILES`, because its cases use the `TAssert` macros and those expand to a
`return NO` that only means anything inside a function that file owns.

Because the input is a fixed list of names, the suite needs no network and
cannot drift: if a project renames its assets the test still says what it
said, and a live run is what notices.

## Measured before and after

The old code against the live catalog, on 2026-09-28, for the releases
below. "Wrong" means it resolved a file that would not run, or failed
outright.

| Project | Old result | New result |
| --- | --- | --- |
| `ipfs-desktop` | **failed**: 301, no tag in the first `Location:` | `ipfs-desktop-0.50.1-linux-x86_64.AppImage` |
| `Obsidian` | **failed**: newest release is a mobile-only `.apk` | `Obsidian-1.13.7.AppImage` |
| `AppImageUpdate` | **wrong**: `AppImageUpdate-aarch64.AppImage` | `AppImageUpdate-x86_64.AppImage` |
| `Audacity` | **wrong**: `audacity-linux-4.0.0-aarch64.AppImage` | `audacity-linux-4.0.0-x86_64.AppImage` |
| `FreeCAD2` | **wrong**: `FreeCAD_1.1.3-Linux-aarch64-py311.AppImage` | `FreeCAD_1.1.3-Linux-x86_64-py311.AppImage` |
| `Motrix` | **wrong**: `Motrix-1.8.19-arm64.AppImage` | `Motrix-1.8.19.AppImage` |
| `qTox` | **failed**: no tag; only pre-releases | `qTox-c0e9a3b7…-x86_64.AppImage` |
| `4KWALL` | correct | correct (via the tie rule) |
| `86Box` | correct, by luck of listing order | `86Box-Linux-x86_64-b9001.AppImage` |
| `Jan` | correct | `Jan_0.8.4_amd64.AppImage` |
| `AppFlowy` | correct | `AppFlowy-0.14.5-linux-x86_64.AppImage` |

Five of the chosen URLs were confirmed to answer HTTP 200 with real sizes. An
actual end-to-end install was **not** verified this way: the resolver picks
the right URL and the URL serves the file, but the
download-into-`~/Applications` half is left to the user's own Get.
