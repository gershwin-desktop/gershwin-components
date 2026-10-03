/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Coverage for +[MenuBarLayout layoutForBarWidth:...]: the pure geometry
 * that decides which of the active app's own menu titles, and which menu
 * extras, a bar of a given width can show without ever clipping a title.
 * Headless - no display, no NSApplication.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../MenuBarLayout.h"

/* Numbers below (in points) are read off the evidence screenshot at
 * GSScaleFactor 2.0 on a 1600-device-pixel-wide screen
 * (/Local/Users/admin/SUPERAGENT/runs/2026-09-27-1040/evidence/menu-scale/2.0/00_baseline_desktop.png):
 * item boundaries were measured by scanning the bar for columns with
 * non-background pixels and halved (device pixels / 2.0 scale = points, the
 * unit the real layout code sizes views in).  Titles up to "Gehe zu" are
 * fully visible in the capture and measured directly; "Werkzeuge",
 * "Fenster" and "Hilfe" are entirely pushed out of frame in that capture
 * (that is the bug), so their widths are estimated from comparably-sized
 * German menu words already on screen - the point of this fixture is the
 * shape of the bug (titles pushed off by extras on a bar too narrow for
 * both), not exact pixel-for-pixel fidelity. */
static NSArray<NSNumber *> *EvidenceTitleWidths(void)
{
    return @[ @51.5,  /* Command (cmd) glyph */
              @94,    /* Workspace */
              @65.5,  /* Ablage */
              @90,    /* Bearbeiten */
              @69,    /* Ansicht */
              @73,    /* Gehe zu */
              @85,    /* Werkzeuge (estimated, off-frame in the capture) */
              @70,    /* Fenster   (estimated, off-frame in the capture) */
              @55 ];  /* Hilfe     (estimated, off-frame in the capture) */
}

static NSArray<NSNumber *> *EvidenceExtraWidths(void)
{
    /* Least-important (nearest the titles) first, matching their
     * left-to-right order in the capture. */
    return @[ @68,    /* CPU "19%" */
              @77.5,  /* RAM/disk "54%" */
              @33,    /* Help "?" */
              @40.5,  /* battery charge icon */
              @33.5,  /* WLAN icon */
              @38,    /* volume icon */
              @52.5 ];/* clock "18:13" */
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* --- Evidence case: GSScaleFactor 2.0, 1600 device px wide screen ---
     * bar width in points = 1600 / 2.0 = 800; the existing code reserves an
     * 8pt margin between the extras and the screen edge (MenuController.m,
     * "- 8" in every extras/widget frame calculation). Titles total 653pt,
     * extras total 343pt: 653 + 343 = 996 does not fit in 792pt, which is
     * exactly the reported bug (titles pushed off by the extras). Once
     * enough extras collapse behind one 28pt overflow item, every title
     * still fits untouched - extras give way first. */
    {
        NSUInteger visibleTitles = 0, collapsedExtras = 0;
        [MenuBarLayout layoutForBarWidth:800.0
                                edgeMargin:8.0
                               titleWidths:EvidenceTitleWidths()
                        titleOverflowWidth:30.0
                               extraWidths:EvidenceExtraWidths()
                        extraOverflowWidth:28.0
                         visibleTitleCount:&visibleTitles
                       collapsedExtraCount:&collapsedExtras];

        PASS(visibleTitles == 9,
             "2.0/1600: every app menu title stays visible (got %lu of 9)",
             (unsigned long)visibleTitles);
        PASS(collapsedExtras == 5,
             "2.0/1600: the five least-important extras collapse behind one overflow item (got %lu)",
             (unsigned long)collapsedExtras);
    }

    /* --- Same content, narrower bar (2.0, 1280 device px wide) ---
     * bar width in points = 1280 / 2.0 = 640, available = 632pt. Even
     * folding every extra behind a single 28pt overflow item leaves only
     * 604pt for 653pt of titles: titles must fold too now, and the rule
     * keeps as many of the leftmost (most-used) ones visible as it can. */
    {
        NSUInteger visibleTitles = 0, collapsedExtras = 0;
        [MenuBarLayout layoutForBarWidth:640.0
                                edgeMargin:8.0
                               titleWidths:EvidenceTitleWidths()
                        titleOverflowWidth:30.0
                               extraWidths:EvidenceExtraWidths()
                        extraOverflowWidth:28.0
                         visibleTitleCount:&visibleTitles
                       collapsedExtraCount:&collapsedExtras];

        PASS(collapsedExtras == 7,
             "2.0/1280: every extra collapses before a single title is touched (got %lu of 7)",
             (unsigned long)collapsedExtras);
        PASS(visibleTitles == 7,
             "2.0/1280: the titles that still do not fit fold into a trailing overflow item (got %lu of 9)",
             (unsigned long)visibleTitles);
    }

    /* --- Everything fits (e.g. GSScaleFactor 1.0/1.25/1.5 on a bar with
     * plenty of room): nothing should collapse or fold - layout must be a
     * no-op when there is no crowding, so existing scale factors are
     * unaffected. --- */
    {
        NSUInteger visibleTitles = 0, collapsedExtras = 0;
        [MenuBarLayout layoutForBarWidth:2000.0
                                edgeMargin:8.0
                               titleWidths:EvidenceTitleWidths()
                        titleOverflowWidth:30.0
                               extraWidths:EvidenceExtraWidths()
                        extraOverflowWidth:28.0
                         visibleTitleCount:&visibleTitles
                       collapsedExtraCount:&collapsedExtras];

        PASS(visibleTitles == 9, "wide bar: no title folds away");
        PASS(collapsedExtras == 0, "wide bar: no extra collapses");
    }

    /* --- No extras loaded: titles alone must still be able to fold. --- */
    {
        NSUInteger visibleTitles = 0, collapsedExtras = 0;
        [MenuBarLayout layoutForBarWidth:300.0
                                edgeMargin:8.0
                               titleWidths:EvidenceTitleWidths()
                        titleOverflowWidth:30.0
                               extraWidths:@[]
                        extraOverflowWidth:28.0
                         visibleTitleCount:&visibleTitles
                       collapsedExtraCount:&collapsedExtras];

        PASS(collapsedExtras == 0, "no extras: nothing to collapse");
        PASS(visibleTitles > 0 && visibleTitles < 9,
             "no extras, narrow bar: titles alone fold (got %lu of 9)",
             (unsigned long)visibleTitles);
    }

    /* --- Exact-fit boundary: available space equals the total exactly. --- */
    {
        NSArray<NSNumber *> *titles = @[ @100.0, @100.0 ];
        NSUInteger visibleTitles = 0, collapsedExtras = 0;
        [MenuBarLayout layoutForBarWidth:208.0   /* 200 titles + 8 margin */
                                edgeMargin:8.0
                               titleWidths:titles
                        titleOverflowWidth:30.0
                               extraWidths:@[]
                        extraOverflowWidth:28.0
                         visibleTitleCount:&visibleTitles
                       collapsedExtraCount:&collapsedExtras];

        PASS(visibleTitles == 2, "exact fit is not treated as overflow");
    }

    [arp release];
    return 0;
}
