/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DBusMenuLayout.h"

static NSString * const kDBusMenuInterface = @"com.canonical.dbusmenu";

@implementation DBusMenuLayout

+ (NSDictionary *)dictionaryFromProperties:(id)propertiesObj
{
    if ([propertiesObj isKindOfClass:[NSDictionary class]]) {
        return propertiesObj;
    }
    if (![propertiesObj isKindOfClass:[NSArray class]]) {
        return [NSDictionary dictionary];
    }
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    for (id element in propertiesObj) {
        if ([element isKindOfClass:[NSDictionary class]]) {
            [merged addEntriesFromDictionary:element];
        }
    }
    return merged;
}

+ (NSDictionary *)propertiesOfLayoutItem:(id)layoutItem
{
    if (![layoutItem isKindOfClass:[NSArray class]] || [layoutItem count] < 3) {
        return [NSDictionary dictionary];
    }
    return [self dictionaryFromProperties:[layoutItem objectAtIndex:1]];
}

+ (BOOL)layoutItemIsEmptySubmenu:(NSArray *)item
{
    NSDictionary *properties = [self propertiesOfLayoutItem:item];
    id children = [item objectAtIndex:2];
    BOOL hasChildren = [children isKindOfClass:[NSArray class]] && [children count] > 0;
    return !hasChildren
        && [[properties objectForKey:@"children-display"] isEqual:@"submenu"];
}

/* Asks the app to create the submenu's children (AboutToShow), then reads
   them.  AboutToShow's "needs update" reply is deliberately ignored: Electron
   answers NO even though it has just created the children. */
+ (NSArray *)fetchSubtreeForItemId:(NSNumber *)itemId
                       serviceName:(NSString *)serviceName
                        objectPath:(NSString *)objectPath
                        connection:(id<DBusMenuLayoutSource>)connection
{
    [connection callMethod:@"AboutToShow"
                 onService:serviceName
                objectPath:objectPath
                 interface:kDBusMenuInterface
                 arguments:[NSArray arrayWithObject:itemId]];
    id reply = [connection callMethod:@"GetLayout"
                            onService:serviceName
                           objectPath:objectPath
                            interface:kDBusMenuInterface
                            arguments:[NSArray arrayWithObjects:itemId,
                                       [NSNumber numberWithInt:-1],
                                       [NSArray array], nil]];
    if (![reply isKindOfClass:[NSArray class]] || [reply count] < 2) {
        return nil;
    }
    id subtree = [reply objectAtIndex:1];
    if (![subtree isKindOfClass:[NSArray class]] || [subtree count] < 3) {
        return nil;
    }
    return subtree;
}

+ (id)fillLayoutItem:(id)layoutItem
         serviceName:(NSString *)serviceName
          objectPath:(NSString *)objectPath
          connection:(id<DBusMenuLayoutSource>)connection
               depth:(NSUInteger)depth
{
    if (![layoutItem isKindOfClass:[NSArray class]] || [layoutItem count] < 3
        || depth >= DBusMenuLayoutMaxDepth) {
        return layoutItem;
    }
    NSArray *item = layoutItem;
    NSNumber *itemId = [item objectAtIndex:0];

    /* The root (id 0) is never a hole: its children are what GetLayout of
       the whole tree already returned. */
    if ([itemId isKindOfClass:[NSNumber class]] && [itemId intValue] != 0
        && [self layoutItemIsEmptySubmenu:item]) {
        NSArray *fetched = [self fetchSubtreeForItemId:itemId
                                           serviceName:serviceName
                                            objectPath:objectPath
                                            connection:connection];
        if (fetched == nil) {
            return item;
        }
        /* Keep the properties we already had for the item itself; only the
           children were missing. */
        item = [NSArray arrayWithObjects:itemId, [item objectAtIndex:1],
                [fetched objectAtIndex:2], nil];
    }

    id children = [item objectAtIndex:2];
    if (![children isKindOfClass:[NSArray class]] || [children count] == 0) {
        return item;
    }
    NSMutableArray *filledChildren = [NSMutableArray arrayWithCapacity:[children count]];
    BOOL changed = NO;
    for (id child in children) {
        id filledChild = [self fillLayoutItem:child
                                  serviceName:serviceName
                                   objectPath:objectPath
                                   connection:connection
                                        depth:depth + 1];
        changed = changed || (filledChild != child);
        [filledChildren addObject:filledChild];
    }
    if (!changed) {
        return item;
    }
    return [NSArray arrayWithObjects:[item objectAtIndex:0], [item objectAtIndex:1],
            filledChildren, nil];
}

+ (id)layoutItem:(id)layoutItem
withLazySubmenusFilledFromService:(NSString *)serviceName
      objectPath:(NSString *)objectPath
      connection:(id<DBusMenuLayoutSource>)connection
{
    return [self fillLayoutItem:layoutItem
                    serviceName:serviceName
                     objectPath:objectPath
                     connection:connection
                          depth:0];
}

+ (NSString *)displayLabel:(NSString *)label
{
    if (![label isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [label stringByReplacingOccurrencesOfString:@"_" withString:@""];
}

+ (BOOL)layoutItemIsVisible:(NSArray *)item
{
    id visible = [[self propertiesOfLayoutItem:item] objectForKey:@"visible"];
    return ![visible respondsToSelector:@selector(boolValue)] || [visible boolValue];
}

+ (NSNumber *)currentIdForTitlePath:(NSArray *)titles
                        fromService:(NSString *)serviceName
                         objectPath:(NSString *)objectPath
                         connection:(id<DBusMenuLayoutSource>)connection
{
    if ([titles count] == 0) {
        return nil;
    }
    id reply = [connection callMethod:@"GetLayout"
                            onService:serviceName
                           objectPath:objectPath
                            interface:kDBusMenuInterface
                            arguments:[NSArray arrayWithObjects:[NSNumber numberWithInt:0],
                                       [NSNumber numberWithInt:-1],
                                       [NSArray array], nil]];
    if (![reply isKindOfClass:[NSArray class]] || [reply count] < 2) {
        return nil;
    }
    NSArray *current = [reply objectAtIndex:1];
    for (NSUInteger level = 0; level < [titles count]; level++) {
        if (![current isKindOfClass:[NSArray class]] || [current count] < 3) {
            return nil;
        }
        /* After a renumbering the submenu on the way may be empty again */
        if (level > 0 && [self layoutItemIsEmptySubmenu:current]) {
            NSArray *fetched = [self fetchSubtreeForItemId:[current objectAtIndex:0]
                                               serviceName:serviceName
                                                objectPath:objectPath
                                                connection:connection];
            if (fetched == nil) {
                return nil;
            }
            current = fetched;
        }
        NSString *wanted = [titles objectAtIndex:level];
        NSArray *match = nil;
        id children = [current objectAtIndex:2];
        if (![children isKindOfClass:[NSArray class]]) {
            return nil;
        }
        for (id child in children) {
            if (![child isKindOfClass:[NSArray class]] || [child count] < 3
                || ![self layoutItemIsVisible:child]) {
                continue;
            }
            NSString *label = [[self propertiesOfLayoutItem:child] objectForKey:@"label"];
            if ([[self displayLabel:label] isEqualToString:wanted]) {
                match = child;
                break;
            }
        }
        if (match == nil) {
            return nil;
        }
        current = match;
    }
    id itemId = [current objectAtIndex:0];
    return [itemId isKindOfClass:[NSNumber class]] ? itemId : nil;
}

@end
