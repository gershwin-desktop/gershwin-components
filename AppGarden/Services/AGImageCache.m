/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGImageCache.h"
#import "AGFetch.h"

/* Fetch failures of this class only ever reach the caller as one line next
 * to a placeholder image, so they live in their own domain rather than the
 * parser's, which stays reserved for catalog documents. */
static NSString *const AGImageCacheErrorDomain =
    @"io.github.gershwin-desktop.AppGarden.AGImageCache";

enum {
  AGImageCacheErrorDownload = 1, // curl could not fetch the file
  AGImageCacheErrorNotAnImage,   // the file has no image representations
  AGImageCacheErrorBadURL,       // no usable address was given
  AGImageCacheErrorFailedEarlier // asked for once already this launch
};

static NSError *AGImageError(NSInteger code, NSString *text)
{
  return [NSError errorWithDomain:AGImageCacheErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: text }];
}

static void AGDeliver(void (^completion)(NSImage *, NSError *),
                      NSImage *image, NSError *error)
{
  NSImage *result = image;
  NSError *resultError = error;
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    completion(result, resultError);
  }];
}

const NSUInteger AGImageCacheIconPixelSize = 256;
static const NSUInteger kAGMemoryCacheBytes = 32 * 1024 * 1024;

#pragma mark - Memory cache

/* A least-recently-used cache with a byte budget. Not NSCache: this
 * Foundation's NSCache only evicts objects that implement
 * NSDiscardableContent, and NSImage does not, so every icon ever decoded
 * stayed resident and scrolling the catalog grew the process without bound.
 * Main thread only, like everything else that touches the memory cache. */
@interface AGImageMemoryCache : NSObject
- (instancetype)initWithByteLimit:(NSUInteger)byteLimit;
- (NSImage *)imageForKey:(NSString *)key;
- (void)setImage:(NSImage *)image forKey:(NSString *)key cost:(NSUInteger)cost;
@end

@implementation AGImageMemoryCache
{
  NSUInteger _byteLimit;
  NSUInteger _totalCost;
  NSMutableDictionary<NSString *, NSImage *> *_images;
  NSMutableDictionary<NSString *, NSNumber *> *_costs;
  NSMutableArray<NSString *> *_order; /* least recently used first */
}

- (instancetype)initWithByteLimit:(NSUInteger)byteLimit
{
  self = [super init];
  if (self != nil)
    {
      _byteLimit = byteLimit;
      _images = [[NSMutableDictionary alloc] init];
      _costs = [[NSMutableDictionary alloc] init];
      _order = [[NSMutableArray alloc] init];
    }
  return self;
}

- (NSImage *)imageForKey:(NSString *)key
{
  NSImage *image = [_images objectForKey:key];
  if (image != nil)
    {
      [_order removeObject:key];
      [_order addObject:key];
    }
  return image;
}

- (void)removeKey:(NSString *)key
{
  _totalCost -= [[_costs objectForKey:key] unsignedIntegerValue];
  [_images removeObjectForKey:key];
  [_costs removeObjectForKey:key];
  [_order removeObject:key];
}

- (void)setImage:(NSImage *)image forKey:(NSString *)key cost:(NSUInteger)cost
{
  if ([_images objectForKey:key] != nil)
    [self removeKey:key];
  [_images setObject:image forKey:key];
  [_costs setObject:[NSNumber numberWithUnsignedInteger:cost] forKey:key];
  [_order addObject:key];
  _totalCost += cost;
  /* The newest entry always stays, even when it alone exceeds the budget:
   * a screenshot larger than the limit still has to reach the page. */
  while (_totalCost > _byteLimit && [_order count] > 1)
    [self removeKey:[_order firstObject]];
}

@end

/* Bytes the decoded bitmaps of an image occupy, the cost NSCache evicts by. */
static NSUInteger AGDecodedByteCount(NSImage *image)
{
  NSUInteger bytes = 0;
  for (NSImageRep *rep in [image representations])
    {
      if ([rep isKindOfClass:[NSBitmapImageRep class]])
        bytes += [(NSBitmapImageRep *)rep bytesPerRow] * (NSUInteger)[rep pixelsHigh];
      else
        bytes += (NSUInteger)[rep pixelsWide] * (NSUInteger)[rep pixelsHigh] * 4;
    }
  return bytes;
}

/* A box-filtered copy of an 8-bit meshed RGB or RGBA bitmap, no larger than
 * maximumPixelSize on either side. Written by hand because this AppKit has
 * no resampling call that works off the main thread, and drawing on the
 * main thread would cost it a frame per icon. Returns nil when the bitmap
 * is stored some other way (16-bit or planar PNGs), which then stays at its
 * original size. */
static NSBitmapImageRep *AGDownscaledBitmap(NSBitmapImageRep *source,
                                            NSUInteger maximumPixelSize)
{
  NSInteger width = [source pixelsWide];
  NSInteger height = [source pixelsHigh];
  NSInteger samples = [source samplesPerPixel];
  if ([source bitsPerSample] != 8 || [source isPlanar]
      || (samples != 3 && samples != 4) || width <= 0 || height <= 0)
    return nil;

  CGFloat scale = (CGFloat)maximumPixelSize / (CGFloat)MAX(width, height);
  NSInteger targetWidth = MAX(1, (NSInteger)floor(width * scale));
  NSInteger targetHeight = MAX(1, (NSInteger)floor(height * scale));

  NSBitmapImageRep *target = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL
                    pixelsWide:targetWidth
                    pixelsHigh:targetHeight
                 bitsPerSample:8
               samplesPerPixel:samples
                      hasAlpha:(samples == 4)
                      isPlanar:NO
                colorSpaceName:[source colorSpaceName]
                  bitmapFormat:[source bitmapFormat]
                   bytesPerRow:0
                  bitsPerPixel:0];
  if (target == nil)
    return nil;

  const unsigned char *in = [source bitmapData];
  unsigned char *out = [target bitmapData];
  NSInteger inRow = [source bytesPerRow];
  NSInteger inPixel = [source bitsPerPixel] / 8;
  NSInteger outRow = [target bytesPerRow];
  NSInteger outPixel = [target bitsPerPixel] / 8;

  for (NSInteger y = 0; y < targetHeight; y++)
    {
      NSInteger y0 = (y * height) / targetHeight;
      NSInteger y1 = MAX(y0 + 1, ((y + 1) * height) / targetHeight);
      for (NSInteger x = 0; x < targetWidth; x++)
        {
          NSInteger x0 = (x * width) / targetWidth;
          NSInteger x1 = MAX(x0 + 1, ((x + 1) * width) / targetWidth);
          NSUInteger sum[4] = { 0, 0, 0, 0 };
          NSUInteger count = (NSUInteger)((y1 - y0) * (x1 - x0));
          for (NSInteger sy = y0; sy < y1; sy++)
            {
              const unsigned char *row = in + sy * inRow;
              for (NSInteger sx = x0; sx < x1; sx++)
                {
                  const unsigned char *pixel = row + sx * inPixel;
                  for (NSInteger s = 0; s < samples; s++)
                    sum[s] += pixel[s];
                }
            }
          unsigned char *dest = out + y * outRow + x * outPixel;
          for (NSInteger s = 0; s < samples; s++)
            dest[s] = (unsigned char)(sum[s] / count);
        }
    }
  return target;
}

/* Decodes on the calling thread, which is always a background operation:
 * the decode is the expensive part and the main thread must never wait for
 * it. A file with zero representations is not an image, so it leaves the
 * cache - otherwise the same dead bytes would fail on every launch.
 *
 * A bitmap larger than maximumPixelSize is replaced by a downscaled copy:
 * the feed's icons are 512 x 512 while a card shows 96 points, and holding
 * hundreds of them at full size is what made scrolling the catalog grow the
 * process past 400 MB. Zero keeps the original. */
static NSImage *AGDecodeImage(NSString *path, NSUInteger maximumPixelSize,
                              NSError **error)
{
  NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
  if (image != nil && [[image representations] count] > 0)
    {
      NSImageRep *rep = [[image representations] firstObject];
      if (maximumPixelSize > 0 && [rep isKindOfClass:[NSBitmapImageRep class]]
          && ((NSUInteger)[rep pixelsWide] > maximumPixelSize
              || (NSUInteger)[rep pixelsHigh] > maximumPixelSize))
        {
          NSBitmapImageRep *small = AGDownscaledBitmap((NSBitmapImageRep *)rep,
                                                       maximumPixelSize);
          if (small != nil)
            {
              NSImage *replacement = [[NSImage alloc]
                  initWithSize:NSMakeSize([small pixelsWide], [small pixelsHigh])];
              [replacement addRepresentation:small];
              image = replacement;
            }
        }
      return image;
    }

  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
  if (error != NULL)
    *error = AGImageError(AGImageCacheErrorNotAnImage,
        NSLocalizedString(@"Not an image", @""));
  return nil;
}

/* Fetches one URL into tmpPath and moves it onto destPath. Returns nil on
 * success, or the error the caller delivers. curl -f turns an HTTP error
 * page into a non-zero exit, so a404 body never reaches the cache. */
static NSError *AGDownloadImage(NSString *urlString, NSString *tmpPath,
                                NSString *destPath)
{
  NSArray *arguments = @[ @"-fsSL", @"--max-time", @"30",
                          @"-o", tmpPath, urlString ];
  NSString *reason = nil;
  int status = AGRunCurl(arguments, &reason);
  NSFileManager *fm = [NSFileManager defaultManager];

  if (status != 0)
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      if (reason == nil)
        reason = @"curl failed"; // only when curl died without a message
      NSString *text = [NSString stringWithFormat:
          NSLocalizedString(@"Could not download the image: %@", @""), reason];
      return AGImageError(AGImageCacheErrorDownload, text);
    }

  NSDictionary *attributes = [fm attributesOfItemAtPath:tmpPath error:NULL];
  if (attributes == nil || [attributes fileSize] == 0)
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      return AGImageError(AGImageCacheErrorDownload,
          NSLocalizedString(@"Could not download the image: no data arrived.",
                             @""));
    }

  [fm removeItemAtPath:destPath error:NULL];
  NSError *moveError = nil;
  if (![fm moveItemAtPath:tmpPath toPath:destPath error:&moveError])
    {
      [fm removeItemAtPath:tmpPath error:NULL];
      NSString *text = [NSString stringWithFormat:
          NSLocalizedString(@"Could not download the image: %@", @""),
          [moveError localizedDescription]];
      return AGImageError(AGImageCacheErrorDownload, text);
    }
  return nil;
}

@implementation AGImageCache
{
  NSString *_imagesDirectory;
  AGImageMemoryCache *_memory;
  NSOperationQueue *_queue;
  /* URL string -> the completions waiting for its in-flight fetch, so two
   * cards that want the same icon share one curl. Guarded by _lock because
   * requests and cancelRequestsForURL: arrive from the main thread while
   * operations finish on the queue. */
  NSMutableDictionary<NSString *, NSMutableArray *> *_pending;
  NSMutableSet<NSString *> *_failedURLs;
  NSLock *_lock;
}

- (instancetype)initWithCacheDirectory:(NSString *)directory
{
  self = [super init];
  if (self)
    {
      NSString *base = (directory != nil) ? directory
                                          : AGDefaultCacheDirectory();
      _imagesDirectory = [[base stringByAppendingPathComponent:@"images"] copy];
      // The budget holds a hundred-odd downscaled icons, enough for a few
      // screens of cards in either direction, while keeping the process
      // under the 150 MB of the brief after scrolling the whole catalog.
      _memory = [[AGImageMemoryCache alloc] initWithByteLimit:kAGMemoryCacheBytes];
      _queue = [[NSOperationQueue alloc] init];
      [_queue setMaxConcurrentOperationCount:4];
      _pending = [[NSMutableDictionary alloc] init];
      _failedURLs = [[NSMutableSet alloc] init];
      _lock = [[NSLock alloc] init];
      [[NSFileManager defaultManager] createDirectoryAtPath:_imagesDirectory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
    }
  return self;
}

- (instancetype)init
{
  return [self initWithCacheDirectory:nil];
}

- (NSImage *)cachedImageForURL:(NSURL *)url
{
  if (url == nil)
    return nil;
  return [_memory imageForKey:[url absoluteString]];
}

- (void)imageForURL:(NSURL *)url
         completion:(void (^)(NSImage *image, NSError *error))completion
{
  [self imageForURL:url maximumPixelSize:0 completion:completion];
}

- (void)imageForURL:(NSURL *)url
   maximumPixelSize:(NSUInteger)maximumPixelSize
         completion:(void (^)(NSImage *image, NSError *error))completion
{
  if (completion == nil)
    return;
  if (url == nil || [[url path] length] == 0)
    {
      AGDeliver(completion, nil, AGImageError(AGImageCacheErrorBadURL,
          NSLocalizedString(@"No image URL was given.", @"")));
      return;
    }

  NSString *key = [url absoluteString];
  NSImage *hit = [_memory imageForKey:key];
  if (hit != nil)
    {
      AGDeliver(completion, hit, nil);
      return;
    }

  [_lock lock];
  if ([_failedURLs containsObject:key])
    {
      [_lock unlock];
      // Answered from the session's memory of the failure, not from the
      // network: one dead URL costs at most one request per launch, or a
      // scroll would turn into a request storm.
      AGDeliver(completion, nil, AGImageError(AGImageCacheErrorFailedEarlier,
          NSLocalizedString(@"This image failed to load earlier in this session.",
                             @"")));
      return;
    }
  NSMutableArray *waiters = [_pending objectForKey:key];
  if (waiters != nil)
    {
      [waiters addObject:[completion copy]];
      [_lock unlock];
      return;
    }
  [_pending setObject:[NSMutableArray arrayWithObject:[completion copy]]
               forKey:key];
  [_lock unlock];

  AGImageCache *blockSelf = self;
  NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
    [blockSelf fetchURL:url key:key maximumPixelSize:maximumPixelSize];
  }];
  [_queue addOperation:operation];
}

- (void)cancelRequestsForURL:(NSURL *)url
{
  if (url == nil)
    return;
  [_lock lock];
  NSMutableArray *waiters = [_pending objectForKey:[url absoluteString]];
  // Drop the callbacks but keep the entry: the download already running
  // answers whoever asks next for this URL, and a card that scrolled back
  // in should not start a second curl for the same bytes.
  [waiters removeAllObjects];
  [_lock unlock];
}

#pragma mark - Private

/* The file name is the URL's path percent-escaped with only ASCII
 * alphanumerics, ".", "-" and "_" left alone. No digest instead: this
 * Foundation ships no hash function, the feed's paths are short enough for
 * any filesystem's name limit, and a reversible name lets a human find the
 * file behind a URL while debugging the cache. */
- (NSString *)diskPathForURL:(NSURL *)url
{
  NSMutableCharacterSet *allowed = [[NSMutableCharacterSet alloc] init];
  [allowed addCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
  NSString *name = [[url path]
      stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  return [_imagesDirectory stringByAppendingPathComponent:name];
}

- (void)fetchURL:(NSURL *)url key:(NSString *)key maximumPixelSize:(NSUInteger)maximumPixelSize
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *path = [self diskPathForURL:url];
  NSImage *image = nil;
  NSError *error = nil;

  if ([fm fileExistsAtPath:path])
    {
      image = AGDecodeImage(path, maximumPixelSize, &error);
    }
  else
    {
      NSString *tmpPath = [path stringByAppendingFormat:@".%@.part",
          [[NSUUID UUID] UUIDString]];
      error = AGDownloadImage([url absoluteString], tmpPath, path);
      if (error == nil)
        image = AGDecodeImage(path, maximumPixelSize, &error);
    }

  [self finishKey:key image:image error:error];
}

- (void)finishKey:(NSString *)key image:(NSImage *)image error:(NSError *)error
{
  NSMutableArray *waiters = nil;
  [_lock lock];
  waiters = [[_pending objectForKey:key] copy];
  [_pending removeObjectForKey:key];
  if (image == nil)
    [_failedURLs addObject:key];
  [_lock unlock];

  if (image != nil)
    [_memory setImage:image forKey:key cost:AGDecodedByteCount(image)];
  if ([waiters count] == 0)
    return;

  NSImage *result = image;
  NSError *resultError = error;
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    id waiter;
    for (waiter in waiters)
      {
        void (^callback)(NSImage *, NSError *) = waiter;
        callback(result, resultError);
      }
  }];
}

@end
