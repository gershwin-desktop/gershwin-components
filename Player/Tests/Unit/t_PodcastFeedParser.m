/* t_PodcastFeedParser.m - ObjectTesting coverage for PodcastFeedParser.
 * Headless: feeds a fixed RSS string straight to -parseFeedData:, no
 * network and no run loop.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../PodcastChapter.m"
#include "../../PodcastEpisode.m"
#include "../../PodcastFeedParser.m"

static NSString *const kSampleFeed =
    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    @"<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\""
    @" xmlns:psc=\"http://podlove.org/simple-chapters\""
    @" xmlns:podcast=\"https://podcastindex.org/namespace/1.0\">"
    @"<channel>"
    @"<title>Test Show</title>"
    @"<item>"
    @"<title>Episode One</title>"
    @"<pubDate>Tue, 01 Oct 2024 12:00:00 +0000</pubDate>"
    @"<itunes:duration>125</itunes:duration>"
    @"<guid>ep-1</guid>"
    // Real feeds wrap this in CDATA (delivered via a different NSXMLParser
    // callback than plain text, -foundCDATA: not -foundCharacters:) - a
    // plain-text fixture here would not catch a parser that misses it.
    @"<description><![CDATA[First episode]]></description>"
    @"<enclosure url=\"https://example.com/ep1.mp3\" length=\"12345\" type=\"audio/mpeg\"/>"
    @"<psc:chapters version=\"1.2\">"
    @"<psc:chapter start=\"00:01:05.500\" title=\"Main topic\"/>"
    @"<psc:chapter start=\"00:00:00.000\" title=\"Intro\"/>"
    @"</psc:chapters>"
    @"</item>"
    @"<item>"
    @"<title>Episode Two</title>"
    @"<pubDate>Wed, 02 Oct 2024 08:30:00 GMT</pubDate>"
    @"<itunes:duration>1:02:03</itunes:duration>"
    @"<guid>ep-2</guid>"
    @"<enclosure url=\"https://example.com/ep2.mp3\" length=\"23456\" type=\"audio/mpeg\"/>"
    @"<podcast:chapters url=\"https://example.com/ep2-chapters.json\" type=\"application/json+chapters\"/>"
    @"</item>"
    @"<item>"
    @"<title>No audio, should be skipped</title>"
    @"<guid>ep-3</guid>"
    @"</item>"
    @"</channel>"
    @"</rss>";

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    NSData *data = [kSampleFeed dataUsingEncoding:NSUTF8StringEncoding];
    PodcastFeedParser *parser = [[[PodcastFeedParser alloc] init] autorelease];
    NSArray *episodes = [parser parseFeedData:data];

    /* --- only <item>s with an <enclosure> become episodes --- */
    {
        PASS_EQUAL(@([episodes count]), @2,
                   "an <item> with no <enclosure> is skipped - there is nothing to stream");
    }

    /* --- first episode: plain-seconds duration, numeric-offset pubDate --- */
    {
        PodcastEpisode *ep = [episodes objectAtIndex:0];
        PASS_EQUAL([ep title], @"Episode One", "title comes from <title>");
        PASS_EQUAL([ep streamURL], @"https://example.com/ep1.mp3", "streamURL comes from <enclosure url>");
        PASS_EQUAL([ep mimeType], @"audio/mpeg", "mimeType comes from <enclosure type>");
        PASS_EQUAL([ep guid], @"ep-1", "guid comes from <guid>");
        PASS_EQUAL([ep summary], @"First episode",
                   "summary reads a CDATA-wrapped <description> (foundCDATA:, not foundCharacters:)");
        PASS_EQUAL([ep formattedDuration], @"2:05",
                   "a plain-seconds <itunes:duration> (125) formats as minutes:seconds");
        PASS(ep.pubDate != nil, "the numeric-offset pubDate (+0000) parses to a date");

        NSArray *chapters = [ep chapters];
        PASS_EQUAL(@([chapters count]), @2, "two <psc:chapter> elements become two chapters");
        PodcastChapter *first = [chapters objectAtIndex:0];
        PodcastChapter *second = [chapters objectAtIndex:1];
        PASS_EQUAL([first title], @"Intro",
                   "chapters are sorted by start time, not feed order (feed wrote Main topic first)");
        PASS(EQ([first startTime], 0.0), "the first chapter starts at 0:00");
        PASS_EQUAL([second title], @"Main topic", "the later chapter sorts second");
        PASS(EQ([second startTime], 65.5), "00:01:05.500 parses to 65.5 seconds");
    }

    /* --- second episode: already H:MM:SS duration, GMT-name pubDate --- */
    {
        PodcastEpisode *ep = [episodes objectAtIndex:1];
        PASS_EQUAL([ep title], @"Episode Two", "title comes from <title>");
        PASS_EQUAL([ep formattedDuration], @"1:02:03",
                   "a duration already written as H:MM:SS passes through unchanged");
        PASS(ep.pubDate != nil, "the zone-name pubDate (GMT) parses to a date");
        PASS([ep chapters] == nil, "no inline <psc:chapters> here, so -chapters stays nil");
        PASS_EQUAL([ep chaptersURL], @"https://example.com/ep2-chapters.json",
                   "<podcast:chapters url> is captured for a lazy fetch when the episode plays");
    }

    /* --- PodcastChapter time parsing, directly --- */
    {
        PASS(EQ([PodcastChapter secondsFromPSCTimeString:@"00:01:05.500"], 65.5),
             "H:MM:SS.mmm parses correctly");
        PASS(EQ([PodcastChapter secondsFromPSCTimeString:@"1:23"], 83.0),
             "M:SS (no hours, no fraction) parses correctly");
        PASS(EQ([PodcastChapter secondsFromPSCTimeString:@"83"], 83.0),
             "plain seconds (no colon) parses correctly");
        PASS(EQ([PodcastChapter secondsFromPSCTimeString:@"01:02:03"], 3723.0),
             "H:MM:SS (no fraction) parses correctly");
    }

    [arp release];
    return 0;
}
