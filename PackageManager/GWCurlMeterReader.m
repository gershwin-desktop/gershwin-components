/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GWCurlMeterReader.h"
#import "GWPackageManager.h"

/*
 * The percent that closes one meter update ("#### 42.0%"), or -1 when the
 * text is not an update: curl's own messages end in something else, and the
 * meter of a transfer whose size the server never declared is a spinner that
 * carries no percent at all - which is the reader's way of saying nothing is
 * measurable yet.
 *
 * Requiring digits before the '%' and refusing any letter in what precedes
 * them keeps prose ("need 42% more") out of the bar while leaving the bar's
 * own characters free to change with curl's version.
 */
static float GWCurlMeterPercent(NSString *segment)
{
  NSUInteger length = [segment length];
  while (length > 0 && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
                        characterIsMember:[segment characterAtIndex:length - 1]])
    length--;
  if (length == 0 || [segment characterAtIndex:length - 1] != '%')
    return -1.0f;

  NSUInteger end = length - 1;   /* the index of '%' */
  NSUInteger start = end;
  BOOL sawDigit = NO;
  while (start > 0)
    {
      unichar c = [segment characterAtIndex:start - 1];
      if (c >= '0' && c <= '9')
        {
          sawDigit = YES;
          start--;
        }
      else if (c == '.' && sawDigit)
        start--;
      else
        break;
    }
  if (!sawDigit || start == end)
    return -1.0f;

  double percent = [[segment substringWithRange:NSMakeRange(start, end - start)]
                    doubleValue];
  if (percent < 0.0 || percent > 100.0)
    return -1.0f;

  NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
  if ([[segment substringToIndex:start]
       rangeOfCharacterFromSet:letters].location != NSNotFound)
    return -1.0f;

  return (float)percent;
}

@implementation GWCurlMeterReader
{
  id<GWInstallProgressHandler> _progress;
  NSString *_message;
  float _firstValue;
  float _lastValue;
  NSMutableString *_pending;    /* the segment cut in half by a chunk boundary */
  float _lastPercent;           /* -1 until the first update arrived */
}

- (instancetype)initWithProgress:(id<GWInstallProgressHandler>)progress
                         message:(NSString *)message
                           first:(float)firstValue
                             last:(float)lastValue
{
  self = [super init];
  if (self)
    {
      _progress = progress;
      _message = [message copy];
      _firstValue = firstValue;
      _lastValue = lastValue;
      _pending = [NSMutableString string];
      _lastPercent = -1.0f;
    }
  return self;
}

- (void)ingestData:(NSData *)data
{
  if ([data length] == 0)
    return;

  /* One character per byte: the meter is ASCII, so a chunk boundary cannot
   * split a sequence the reader would have to reassemble, and the decode
   * cannot fail on bytes curl wrote in some other encoding. */
  NSString *chunk = [[NSString alloc] initWithData:data
                                          encoding:NSISOLatin1StringEncoding];
  if (chunk == nil)
    return;
  [_pending appendString:chunk];

  /* A segment is only complete once its carriage return or newline has been
   * read; consuming it earlier would parse half an update. */
  NSCharacterSet *ends = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
  for (;;)
    {
      NSRange hit = [_pending rangeOfCharacterFromSet:ends];
      if (hit.location == NSNotFound)
        return;
      NSString *segment = [_pending substringToIndex:hit.location];
      [_pending deleteCharactersInRange:NSMakeRange(0, NSMaxRange(hit))];
      [self consumeSegment:segment];
    }
}

- (void)finish
{
  if ([_pending length] == 0)
    return;
  NSString *segment = _pending;
  _pending = [NSMutableString string];
  [self consumeSegment:segment];
}

/* Defined only so the interface's NS_UNAVAILABLE entry has a body; the
 * attribute keeps callers out and the route to the designated initializer
 * keeps the compiler's initializer chain well formed. */
- (instancetype)init
{
  return [self initWithProgress:nil message:nil first:0.0f last:0.0f];
}

- (void)consumeSegment:(NSString *)segment
{
  float percent = GWCurlMeterPercent(segment);
  if (percent < 0.0f)
    {
      /* curl's own text. It is not progress, but it is the only place the
       * reason for a failure exists ("curl: (22) ... error: 403"), so it
       * goes out as a line instead of being dropped. */
      [GWCurlMeterReader forwardSegment:segment toProgress:_progress];
      return;
    }

  /* One report per whole percent. The meter ticks faster than a bar moves
   * and every report is a message the main thread has to pick up. */
  if (_lastPercent >= 0.0f && (int)percent == (int)_lastPercent)
    return;
  _lastPercent = percent;

  float value = _firstValue + (_lastValue - _firstValue) * (percent / 100.0f);
  [_progress installDidProgress:value message:_message];
}

+ (NSString *)outputLineForSegment:(NSString *)segment
{
  NSString *text = [segment stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([text length] == 0)
    return nil;

  /* The meter without a percent is a run of glyphs ("#=#=#"), drawn from
   * the bar's own characters, and no sentence anywhere is made of those
   * alone. Walk the letters instead: "o" and "O" are glyph faces the
   * spinner may use, any other letter means curl is writing words. */
  NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
  NSUInteger searched = 0;
  for (;;)
    {
      NSRange rest = NSMakeRange(searched, [text length] - searched);
      NSRange hit = [text rangeOfCharacterFromSet:letters options:0 range:rest];
      if (hit.location == NSNotFound)
        return nil;
      unichar c = [text characterAtIndex:hit.location];
      if (c != 'o' && c != 'O')
        return text;
      searched = NSMaxRange(hit);
    }
}

/* One segment, out to the handler as text if it is text. Shared by the
 * reader's own stream and by the pipe reader below, so both apply the same
 * rule about what is a line and what is the meter drawing. */
+ (void)forwardSegment:(NSString *)segment
           toProgress:(id<GWInstallProgressHandler>)progress
{
  if (progress == nil
      || ![progress respondsToSelector:@selector(installDidOutputLine:)])
    return;
  NSString *line = [self outputLineForSegment:segment];
  if (line != nil)
    [progress installDidOutputLine:line];
}

+ (void)forwardStderrOfPipe:(NSPipe *)pipe
                 toProgress:(id<GWInstallProgressHandler>)progress
{
  NSFileHandle *handle = [pipe fileHandleForReading];
  NSMutableString *pending = [NSMutableString string];
  NSCharacterSet *ends =
      [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];

  for (;;)
    {
      NSData *chunk = [handle availableData];
      if ([chunk length] == 0)
        break;
      /* Latin 1 cannot fail and cannot split a character: every byte maps,
       * so a chunk boundary only ever lands inside a segment. */
      NSString *text = [[NSString alloc]
          initWithData:chunk encoding:NSISOLatin1StringEncoding];
      if (text == nil)
        continue;
      [pending appendString:text];
      for (;;)
        {
          NSRange hit = [pending rangeOfCharacterFromSet:ends];
          if (hit.location == NSNotFound)
            break;
          NSString *segment = [pending substringToIndex:hit.location];
          [pending deleteCharactersInRange:NSMakeRange(0, NSMaxRange(hit))];
          [self forwardSegment:segment toProgress:progress];
        }
    }

  [self forwardSegment:pending toProgress:progress];
}

@end
