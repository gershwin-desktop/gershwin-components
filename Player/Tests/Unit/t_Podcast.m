/* t_Podcast.m - ObjectTesting coverage for Podcast. Headless.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../Podcast.m"

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* --- initWithDictionary: parses an iTunes Search API result --- */
    {
        NSDictionary *dict = @{
            @"collectionId": @123456,
            @"collectionName": @"The Test Show",
            @"artistName": @"Test Publisher",
            @"artworkUrl600": @"https://example.com/art600.jpg",
            @"artworkUrl100": @"https://example.com/art100.jpg",
            @"feedUrl": @"https://example.com/feed.xml",
            @"primaryGenreName": @"Technology"
        };
        Podcast *show = [[[Podcast alloc] initWithDictionary:dict] autorelease];

        PASS_EQUAL([show collectionId], @"123456", "collectionId stringifies the JSON number");
        PASS_EQUAL([show name], @"The Test Show", "name reads collectionName");
        PASS_EQUAL([show artistName], @"Test Publisher", "artistName reads artistName");
        PASS_EQUAL([show artworkURL], @"https://example.com/art600.jpg",
                   "artworkURL prefers the 600px artwork over the 100px one");
        PASS_EQUAL([show feedURL], @"https://example.com/feed.xml", "feedURL reads feedUrl");
        PASS_EQUAL([show genre], @"Technology", "genre reads primaryGenreName");
    }

    /* --- artworkURL falls back when only a smaller size is present --- */
    {
        NSDictionary *dict = @{
            @"collectionName": @"Small Art Show",
            @"artworkUrl60": @"https://example.com/art60.jpg",
            @"feedUrl": @"https://example.com/small.xml"
        };
        Podcast *show = [[[Podcast alloc] initWithDictionary:dict] autorelease];
        PASS_EQUAL([show artworkURL], @"https://example.com/art60.jpg",
                   "artworkURL falls back to a smaller size when 600/100 are absent");
    }

    /* --- propertyList / podcastWithPropertyList: round trip --- */
    {
        NSDictionary *dict = @{
            @"collectionId": @42,
            @"collectionName": @"Round Trip Show",
            @"artistName": @"Round Tripper",
            @"artworkUrl600": @"https://example.com/round.jpg",
            @"feedUrl": @"https://example.com/round.xml",
            @"primaryGenreName": @"Arts"
        };
        Podcast *original = [[[Podcast alloc] initWithDictionary:dict] autorelease];
        NSDictionary *plist = [original propertyList];
        Podcast *restored = [Podcast podcastWithPropertyList:plist];

        PASS(restored != nil, "podcastWithPropertyList: restores a show from its own propertyList");
        PASS_EQUAL([restored name], [original name], "restored name matches the original");
        PASS_EQUAL([restored feedURL], [original feedURL], "restored feedURL matches the original");
        PASS([original isSamePodcastAs:restored], "the restored show isSamePodcastAs: the original");
    }

    /* --- podcastWithPropertyList: refuses a plist with nothing to subscribe to --- */
    {
        PASS([Podcast podcastWithPropertyList:nil] == nil, "nil plist yields no podcast");
        PASS([Podcast podcastWithPropertyList:@{@"name": @"No Feed"}] == nil,
             "a plist without feedURL yields no podcast - there is nothing to subscribe to");
    }

    /* --- isSamePodcastAs: prefers collectionId, falls back to feedURL --- */
    {
        Podcast *a = [[[Podcast alloc] init] autorelease];
        [a setCollectionId:@"1"];
        [a setFeedURL:@"https://example.com/a.xml"];
        Podcast *b = [[[Podcast alloc] init] autorelease];
        [b setCollectionId:@"1"];
        [b setFeedURL:@"https://example.com/different.xml"];
        PASS([a isSamePodcastAs:b], "same collectionId wins even with a different feedURL");

        Podcast *c = [[[Podcast alloc] init] autorelease];
        [c setFeedURL:@"https://example.com/a.xml"];
        Podcast *d = [[[Podcast alloc] init] autorelease];
        [d setFeedURL:@"https://example.com/a.xml"];
        PASS([c isSamePodcastAs:d], "same feedURL wins when neither has a collectionId");

        Podcast *e = [[[Podcast alloc] init] autorelease];
        [e setFeedURL:@"https://example.com/a.xml"];
        Podcast *f = [[[Podcast alloc] init] autorelease];
        [f setFeedURL:@"https://example.com/b.xml"];
        PASS(![e isSamePodcastAs:f], "different feedURLs are different shows");
    }

    [arp release];
    return 0;
}
