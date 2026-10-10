/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWRepositoryList.h"

NSString *const SWRepositoryListErrorDomain = @"SWRepositoryListErrorDomain";

/* The platform this Software Update was built for, in the words of the
 * Platforms column of Repositories.csv. */
static NSString *SWCurrentPlatform(void)
{
#ifdef _WIN32
  return @"windows";
#else
  return @"unix";
#endif
}

/* Whether a repository is for this platform: the Platforms column is empty
 * (everywhere) or lists it.  A repository for another platform is not checked
 * out here - the Windows theme is a Windows-only repository - so listing it
 * would only report it as one that could not be checked. */
static BOOL SWPlatformsIncludeCurrent(NSString *platforms)
{
  NSString *list = [platforms stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([list length] == 0) return YES;
  return [[list componentsSeparatedByCharactersInSet:
    [NSCharacterSet whitespaceCharacterSet]] containsObject:SWCurrentPlatform()];
}

@implementation SWRepositoryList

+ (NSArray<SWRepository *> *)repositoriesFromCSVAtPath:(NSString *)path
                                                  error:(NSError **)error
{
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data) {
    if (error) {
      *error = [NSError errorWithDomain:SWRepositoryListErrorDomain
                                    code:SWRepositoryListErrorFileNotFound
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"No such file: %@", path]
                                }];
    }
    return nil;
  }
  return [self repositoriesFromCSVData:data error:error];
}

+ (NSArray<SWRepository *> *)repositoriesFromCSVData:(NSData *)data
                                                error:(NSError **)error
{
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  NSMutableArray *repositories = [NSMutableArray array];

  for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([line length] == 0 || [line hasPrefix:@"#"]) continue;

    NSArray<NSString *> *fields = [line componentsSeparatedByString:@","];
    if ([fields count] < 2) continue; // not a well-formed Name,URL,... row

    NSString *name = fields[0];
    if ([name isEqualToString:@"Name"]) continue; // header row

    // An optional fifth column limits the repository to some platforms.
    if ([fields count] > 4 && !SWPlatformsIncludeCurrent(fields[4])) continue;

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    [entry setObject:name forKey:@"Name"];
    [entry setObject:fields[1] forKey:@"URL"];
    if ([fields count] > 2 && [fields[2] length] > 0) {
      [entry setObject:fields[2] forKey:@"Pin"];
    }
    if ([fields count] > 3 && [fields[3] isEqualToString:@"YES"]) {
      [entry setObject:@YES forKey:@"RestartRequired"];
    }

    [repositories addObject:[[SWRepository alloc] initWithPlistEntry:entry]];
  }

  if ([repositories count] == 0) {
    if (error) {
      *error = [NSError errorWithDomain:SWRepositoryListErrorDomain
                                    code:SWRepositoryListErrorMalformed
                                userInfo:@{
                                  NSLocalizedDescriptionKey: @"Repositories.csv has no repository rows"
                                }];
    }
    return nil;
  }

  return [repositories copy];
}

@end
