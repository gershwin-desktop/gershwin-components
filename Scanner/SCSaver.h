/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "SCImageWriter.h"

/* Posted on the main thread after every save; userInfo "paths" lists the files */
extern NSString * const SCSaverDidSaveNotification;

/* Called on the main thread with the paths written, or nil and the error */
typedef void (^SCSaveCompletion)(NSArray *paths, NSError *error);

/*
 * Saves the pages of one scan with the user's preferences: numbered files
 * in the chosen folder, all pages in one file for PDF. A PDF with text
 * recognition is made on a worker thread, which takes seconds per page;
 * everything else is written before the call returns.
 */
@interface SCSaver : NSObject

/* YES when saving in this format will run text recognition */
+ (BOOL) recognizesTextForFormat: (SCFileFormat)format;

+ (void) saveImages: (NSArray *)images format: (SCFileFormat)format
         completion: (SCSaveCompletion)completion;

/* Into an explicit file (pages numbered after it for one-page formats) */
+ (void) saveImages: (NSArray *)images toPath: (NSString *)path
         completion: (SCSaveCompletion)completion;

@end
