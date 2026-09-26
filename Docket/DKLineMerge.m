/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKLineMerge.h"

/* One base-relative change: base[aStart,aEnd) became other[bStart,bEnd)
 * on the side named by fromLocal. Only non-equal (changed) regions are
 * ever represented; unchanged base lines never get one, they are
 * copied through directly by the caller. */
@interface _DKRegion : NSObject
{
@public
  NSUInteger aStart, aEnd;
  NSUInteger bStart, bEnd;
  BOOL fromLocal;
}
@end
@implementation _DKRegion
@end

static NSArray *
DKSplitLines(NSString *s)
{
  return [s componentsSeparatedByString: @"\n"];
}

/* Longest-common-subsequence backtrack between two line arrays, returning
 * an ordered array of (i,j) index pairs (each a 2-element NSArray of
 * NSNumber) naming the lines that match between a and b. */
static NSArray *
DKMatchPairs(NSArray *a, NSArray *b)
{
  NSUInteger n = [a count];
  NSUInteger m = [b count];
  NSUInteger *dp = calloc((n + 1) * (m + 1), sizeof(NSUInteger));
  NSMutableArray *matches = [NSMutableArray array];
  NSUInteger i, j;

  if (dp == NULL)
    {
      [NSException raise: NSMallocException format: @"DKLineMerge: out of memory"];
    }

#define DKDP(i, j) dp[(i) * (m + 1) + (j)]

  for (i = 1; i <= n; i++)
    {
      for (j = 1; j <= m; j++)
        {
          if ([[a objectAtIndex: i - 1] isEqualToString: [b objectAtIndex: j - 1]])
            {
              DKDP(i, j) = DKDP(i - 1, j - 1) + 1;
            }
          else
            {
              NSUInteger up = DKDP(i - 1, j);
              NSUInteger left = DKDP(i, j - 1);
              DKDP(i, j) = (up >= left) ? up : left;
            }
        }
    }

  i = n;
  j = m;
  while (i > 0 && j > 0)
    {
      if ([[a objectAtIndex: i - 1] isEqualToString: [b objectAtIndex: j - 1]])
        {
          NSNumber *ni = [NSNumber numberWithUnsignedInteger: i - 1];
          NSNumber *nj = [NSNumber numberWithUnsignedInteger: j - 1];
          [matches insertObject: [NSArray arrayWithObjects: ni, nj, nil] atIndex: 0];
          i--;
          j--;
        }
      else if (DKDP(i - 1, j) >= DKDP(i, j - 1))
        {
          i--;
        }
      else
        {
          j--;
        }
    }

#undef DKDP
  free(dp);
  return matches;
}

/* Turns the gaps between matched lines into change regions (base[aStart,
 * aEnd) replaced by other[bStart,bEnd)); a region with aStart==aEnd is a
 * pure insertion, one with bStart==bEnd a pure deletion. */
static void
DKAppendChangeRegions(NSArray *a, NSArray *b, NSArray *matches, NSMutableArray *outRegions, BOOL fromLocal)
{
  NSUInteger prevA = 0, prevB = 0;
  NSUInteger n = [a count], m = [b count];

  for (NSArray *pair in matches)
    {
      NSUInteger mi = [[pair objectAtIndex: 0] unsignedIntegerValue];
      NSUInteger mj = [[pair objectAtIndex: 1] unsignedIntegerValue];

      if (mi > prevA || mj > prevB)
        {
          _DKRegion *r = [[_DKRegion alloc] init];
          r->aStart = prevA; r->aEnd = mi;
          r->bStart = prevB; r->bEnd = mj;
          r->fromLocal = fromLocal;
          [outRegions addObject: r];
          [r release];
        }
      prevA = mi + 1;
      prevB = mj + 1;
    }

  if (prevA < n || prevB < m)
    {
      _DKRegion *r = [[_DKRegion alloc] init];
      r->aStart = prevA; r->aEnd = n;
      r->bStart = prevB; r->bEnd = m;
      r->fromLocal = fromLocal;
      [outRegions addObject: r];
      [r release];
    }
}

static NSInteger
DKRegionCompare(id a, id b, void *context)
{
  _DKRegion *ra = (_DKRegion *)a;
  _DKRegion *rb = (_DKRegion *)b;

  if (ra->aStart < rb->aStart) return NSOrderedAscending;
  if (ra->aStart > rb->aStart) return NSOrderedDescending;
  return NSOrderedSame;
}

/* Reconstructs one side's version of base[cStart,cEnd) by replaying that
 * side's change regions inside the cluster and filling every gap between
 * them with the matching base lines (a position inside the cluster that
 * has no region for this side is, by construction, unchanged on this
 * side - see the module comment in DKLineMerge.h). */
static NSArray *
DKReconstructSide(NSArray *baseLines, NSArray *sideLines, NSArray *clusterRegionsForSide,
                   NSUInteger cStart, NSUInteger cEnd)
{
  NSMutableArray *result = [NSMutableArray array];
  NSUInteger pos = cStart;

  for (_DKRegion *r in clusterRegionsForSide)
    {
      if (r->aStart > pos)
        {
          [result addObjectsFromArray:
            [baseLines subarrayWithRange: NSMakeRange(pos, r->aStart - pos)]];
        }
      if (r->bEnd > r->bStart)
        {
          [result addObjectsFromArray:
            [sideLines subarrayWithRange: NSMakeRange(r->bStart, r->bEnd - r->bStart)]];
        }
      pos = r->aEnd;
    }
  if (cEnd > pos)
    {
      [result addObjectsFromArray:
        [baseLines subarrayWithRange: NSMakeRange(pos, cEnd - pos)]];
    }
  return result;
}

@implementation DKLineMerge

+ (NSString *)mergeBase: (NSString *)base
                   local: (NSString *)local
                  remote: (NSString *)remote
                conflict: (BOOL *)hasConflict
{
  NSArray *baseLines, *localLines, *remoteLines;
  NSMutableArray *regions;
  NSMutableArray *clusters;
  NSMutableArray *currentCluster = nil;
  NSUInteger currentEnd = 0;
  NSMutableArray *outLines;
  NSUInteger pos;
  BOOL conflict = NO;

  if ([local isEqualToString: base])
    {
      if (hasConflict != NULL) *hasConflict = NO;
      return remote;
    }
  if ([remote isEqualToString: base] || [local isEqualToString: remote])
    {
      if (hasConflict != NULL) *hasConflict = NO;
      return local;
    }

  baseLines = DKSplitLines(base);
  localLines = DKSplitLines(local);
  remoteLines = DKSplitLines(remote);

  regions = [NSMutableArray array];
  DKAppendChangeRegions(baseLines, localLines, DKMatchPairs(baseLines, localLines), regions, YES);
  DKAppendChangeRegions(baseLines, remoteLines, DKMatchPairs(baseLines, remoteLines), regions, NO);
  [regions sortUsingFunction: DKRegionCompare context: NULL];

  clusters = [NSMutableArray array];
  for (_DKRegion *r in regions)
    {
      if (currentCluster != nil && r->aStart < currentEnd)
        {
          [currentCluster addObject: r];
          if (r->aEnd > currentEnd)
            {
              currentEnd = r->aEnd;
            }
        }
      else
        {
          currentCluster = [NSMutableArray arrayWithObject: r];
          [clusters addObject: currentCluster];
          currentEnd = r->aEnd;
        }
    }

  outLines = [NSMutableArray array];
  pos = 0;

  for (NSMutableArray *cluster in clusters)
    {
      NSUInteger cStart = NSUIntegerMax, cEnd = 0;
      BOOL hasL = NO, hasR = NO;
      NSMutableArray *localRegions = [NSMutableArray array];
      NSMutableArray *remoteRegions = [NSMutableArray array];

      for (_DKRegion *r in cluster)
        {
          if (r->aStart < cStart) cStart = r->aStart;
          if (r->aEnd > cEnd) cEnd = r->aEnd;
          if (r->fromLocal)
            {
              hasL = YES;
              [localRegions addObject: r];
            }
          else
            {
              hasR = YES;
              [remoteRegions addObject: r];
            }
        }

      if (cStart > pos)
        {
          [outLines addObjectsFromArray:
            [baseLines subarrayWithRange: NSMakeRange(pos, cStart - pos)]];
        }
      pos = cEnd;

      if (hasL && !hasR)
        {
          _DKRegion *r = [localRegions objectAtIndex: 0];
          if (r->bEnd > r->bStart)
            {
              [outLines addObjectsFromArray:
                [localLines subarrayWithRange: NSMakeRange(r->bStart, r->bEnd - r->bStart)]];
            }
        }
      else if (hasR && !hasL)
        {
          _DKRegion *r = [remoteRegions objectAtIndex: 0];
          if (r->bEnd > r->bStart)
            {
              [outLines addObjectsFromArray:
                [remoteLines subarrayWithRange: NSMakeRange(r->bStart, r->bEnd - r->bStart)]];
            }
        }
      else
        {
          NSArray *localText = DKReconstructSide(baseLines, localLines, localRegions, cStart, cEnd);
          NSArray *remoteText = DKReconstructSide(baseLines, remoteLines, remoteRegions, cStart, cEnd);

          if ([localText isEqualToArray: remoteText])
            {
              [outLines addObjectsFromArray: localText];
            }
          else
            {
              conflict = YES;
              [outLines addObject: @"<<<<<<< local"];
              [outLines addObjectsFromArray: localText];
              [outLines addObject: @"======="];
              [outLines addObjectsFromArray: remoteText];
              [outLines addObject: @">>>>>>> remote"];
            }
        }
    }

  if ([baseLines count] > pos)
    {
      [outLines addObjectsFromArray:
        [baseLines subarrayWithRange: NSMakeRange(pos, [baseLines count] - pos)]];
    }

  if (hasConflict != NULL)
    {
      *hasConflict = conflict;
    }
  return [outLines componentsJoinedByString: @"\n"];
}

@end
