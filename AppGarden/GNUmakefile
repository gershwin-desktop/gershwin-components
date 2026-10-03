include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = AppGarden
PACKAGE_NAME = AppGarden
AppGarden_PRINCIPAL_CLASS = NSApplication
AppGarden_APPLICATION_ICON = AppGarden.png

# Every source listed explicitly, no wildcards: a file that is not written
# yet fails the build here instead of silently missing a class at runtime.
AppGarden_OBJC_FILES = \
  main.m \
  Models/AGApp.m \
  Models/AGLink.m \
  Models/AGAuthor.m \
  Models/AGCatalog.m \
  Models/AGFeedParser.m \
  Models/AGCategoryNames.m \
  Models/AGLicenseFormatter.m \
  Models/AGSearchIndex.m \
  Models/AGDownloadResolver.m \
  Models/AGGridLayout.m \
  Models/AGDiscoverOrder.m \
  Services/AGFeedLoader.m \
  Services/AGImageCache.m \
  Services/AGInstaller.m \
  Services/AGInstallTask.m \
  Services/AGInstallRegistry.m \
  Controllers/AGAppDelegate.m \
  Controllers/AGMainWindowController.m \
  Controllers/AGSidebarController.m \
  Controllers/AGGridViewController.m \
  Controllers/AGDetailViewController.m \
  Controllers/AGStatusBannerController.m \
  Views/AGAppCardView.m \
  Views/AGAppGridView.m \
  Views/AGInstallButton.m \
  Views/AGScreenshotView.m \
  Views/AGPlaceholderIcon.m \
  Views/AGSourceListCell.m

# Both the icon and English.lproj/ live in Resources/, so the resource search
# root has to be Resources/: gnustep-make reads <root>/<lang>.lproj/<file> for
# LOCALIZED_RESOURCE_FILES, which would miss Resources/English.lproj otherwise.
# The two files still land in AppGarden.app/Resources/ as before.
AppGarden_RESOURCE_FILES = \
  AppGarden.png \
  AppGarden@2x.png \
  Icons/ai.tiff Icons/astronomy.tiff Icons/audio.tiff \
  Icons/back.tiff \
  Icons/audiovideo.tiff Icons/chat.tiff Icons/database.tiff \
  Icons/development.tiff Icons/discover.tiff Icons/downloaded.tiff \
  Icons/education.tiff Icons/electronics.tiff Icons/emulator.tiff \
  Icons/engineering.tiff Icons/finance.tiff Icons/game.tiff \
  Icons/generic.tiff Icons/graphics.tiff Icons/hamradio.tiff \
  Icons/music.tiff Icons/network.tiff Icons/news.tiff \
  Icons/office.tiff Icons/photography.tiff Icons/science.tiff \
  Icons/system.tiff Icons/terminal.tiff Icons/texteditor.tiff \
  Icons/utility.tiff Icons/video.tiff Icons/videoconference.tiff \
  Icons/viewer.tiff Icons/wordprocessor.tiff
AppGarden_RESOURCE_FILES_DIR = Resources
AppGarden_LOCALIZED_RESOURCE_FILES = Localizable.strings
AppGarden_LANGUAGES = English

# Models/, Services/, Controllers/ and Views/ import their neighbours
# unqualified (e.g. "AGCatalog.h").
ADDITIONAL_OBJCFLAGS += -IModels -IServices -IControllers -IViews

# ARC throughout, matching SoftwareUpdate and PackageManager/OnDemand.
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-unused-parameter

# The PackageManager headers come in through -I/System/Library/Headers, a
# non-system include path, so clang reports every unannotated pointer in them.
# They are not ours to annotate (no edits outside this component).
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness
ADDITIONAL_OBJCFLAGS += -I/System/Library/Headers

# Link against the installed PackageManager framework (GWAppImageDownloader);
# do not embed it. No -ldispatch: our sources never call dispatch_*, our
# objects have no undefined dispatch symbols, and libPackageManager.so carries
# its own DT_NEEDED for libdispatch.so, so it is loaded transitively - a probe
# program calling the framework links fine without -ldispatch. SoftwareUpdate
# needs it only because its own code calls dispatch_async.
ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

AppGarden_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

include $(GNUSTEP_MAKEFILES)/application.make

# The sidebar glyphs are drawn as 16-point SVGs; each TIFF carries a 16 px
# 72 dpi page and a 32 px 144 dpi page so NSImage picks a sharp bitmap at
# GSScaleFactor 1 and 2. The TIFFs are committed so that building needs no
# SVG renderer; run "gmake icons" after editing an SVG.
.PHONY: icons
icons:
	set -e; for svg in Resources/Icons/*.svg; do \
	  tiff=$${svg%.svg}.tiff; \
	  inkscape -w 16 -h 16 -o $$tiff.1x.png $$svg; \
	  inkscape -w 32 -h 32 -o $$tiff.2x.png $$svg; \
	  convert \( $$tiff.1x.png -set units PixelsPerInch -set density 72 \) \
	    \( $$tiff.2x.png -set units PixelsPerInch -set density 144 \) \
	    -type TrueColorAlpha -compress lzw -define tiff:alpha=associated $$tiff; \
	  rm -f $$tiff.1x.png $$tiff.2x.png; \
	done
