/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StreamPlayer.h"

#include <time.h>
#include <ao/ao.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

// How far decoding may run ahead of the wall clock.  Keeps the position
// display smooth without letting a paused or stopped stream lag behind.
static const double kWallClockLead = 0.05;

// A frame this far ahead of the clock has a broken timestamp; waiting for
// it would freeze playback.
static const double kMaxFrameWait = 2.0;

static double monotonicSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static NSError *streamError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:@"StreamPlayer"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// One opening of a stream.  It is cancelled on its own, so a playback
// thread still stuck in a host name lookup (which FFmpeg cannot interrupt)
// can be abandoned without the next stream waiting for it.
@interface StreamOpenAttempt : NSObject
{
@public
    volatile BOOL cancelled;
}
@end

@implementation StreamOpenAttempt
@end

@implementation StreamPlayer

@synthesize delegate = _delegate;
@synthesize volume = _volume;
@synthesize muted = _muted;
@synthesize usesAudioDevice = _usesAudioDevice;
@synthesize hasVideo = _hasVideo;
@synthesize videoWidth = _videoWidth;
@synthesize videoHeight = _videoHeight;

// Lets a blocking network read give up as soon as its attempt is
// cancelled, instead of holding -stop until FFmpeg's timeout.
static int interruptCallback(void *opaque)
{
    StreamOpenAttempt *attempt = (StreamOpenAttempt *)opaque;
    return attempt->cancelled ? 1 : 0;
}

+ (void)initialize
{
    if (self == [StreamPlayer class]) {
        // Once per process: libao keeps global driver state, so a second
        // player must not initialize or shut it down again.
        ao_initialize();
    }
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _volume = 1.0f;
        _fadeFrom = 1.0f;
        _fadeTo = 1.0f;
        _usesAudioDevice = YES;
        _pauseCondition = [[NSCondition alloc] init];
        _attempt = [[StreamOpenAttempt alloc] init];
        _seekLock = [[NSLock alloc] init];
        _seekTarget = -1.0;
        _audioStreamIndex = -1;
        _videoStreamIndex = -1;
    }
    return self;
}

- (void)dealloc
{
    [self close];
    [_attempt release];
    [_pauseCondition release];
    [_seekLock release];
    [super dealloc];
}

#pragma mark - Properties

- (BOOL)isPlaying
{
    return _isPlaying;
}

- (void)setVolume:(float)volume
{
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    _volume = volume;
}

#pragma mark - Fading

- (float)fadeGainAt:(double)time
{
    @synchronized(self) {
        if (_fadeDuration <= 0.0 || time >= _fadeStart + _fadeDuration) {
            return _fadeTo;
        }
        double t = MAX(0.0, (time - _fadeStart) / _fadeDuration);
        // Smoothstep, so a fade starts and ends gently
        double eased = t * t * (3.0 - 2.0 * t);
        return _fadeFrom + (float)((_fadeTo - _fadeFrom) * eased);
    }
}

- (float)fadeGain
{
    return [self fadeGainAt:monotonicSeconds()];
}

- (void)setFadeGain:(float)gain
{
    [self fadeToGain:gain duration:0.0];
}

- (void)fadeToGain:(float)gain duration:(NSTimeInterval)duration
{
    double now = monotonicSeconds();
    float current = [self fadeGainAt:now];
    @synchronized(self) {
        _fadeFrom = current;
        _fadeTo = MAX(0.0f, MIN(1.0f, gain));
        _fadeStart = now;
        _fadeDuration = MAX(0.0, duration);
    }
}

- (void)setCurrentURL:(NSString *)url
{
    if (_currentURL != url) {
        [_currentURL release];
        _currentURL = [url copy];
    }
}

- (NSString *)currentURL
{
    return [[_currentURL retain] autorelease];
}

- (double)wallClockPosition
{
    double t = monotonicSeconds() - _clockOrigin;
    if (t < 0.0) {
        t = 0.0;
    }
    if (_totalDuration > 0.0 && t > _totalDuration) {
        t = _totalDuration;
    }
    return t;
}

- (NSTimeInterval)currentTime
{
    if (_clockFromWall && _isPlaying && !_paused) {
        return [self wallClockPosition];
    }
    return _position;
}

- (NSTimeInterval)duration
{
    return _totalDuration;
}

#pragma mark - Public API

- (BOOL)openURL:(NSString *)urlString error:(NSError **)error
{
    if (urlString == nil || [urlString length] == 0) {
        if (error) *error = streamError(-1, @"URL is nil or empty");
        return NO;
    }

    [self close];
    _generation++;
    _shouldStop = NO;
    [_attempt release];
    _attempt = [[StreamOpenAttempt alloc] init];
    return [self openStream:urlString attempt:_attempt error:error];
}

- (void)playURL:(NSString *)urlString
{
    [self close];
    _generation++;
    _shouldStop = NO;
    _connecting = YES;
    [self setCurrentURL:urlString];
    [_attempt release];
    _attempt = [[StreamOpenAttempt alloc] init];

    // Connecting to a network stream can take seconds; the playback thread
    // does it, so the caller's run loop keeps going.
    _playbackThread = [[NSThread alloc] initWithTarget:self
                                              selector:@selector(openAndPlay:)
                                                object:@[urlString, @(_generation), _attempt]];
    [_playbackThread start];
}

- (BOOL)isConnecting
{
    return _connecting;
}

- (void)openAndPlay:(NSArray *)args
{
    @autoreleasepool {
        NSString *urlString = [args objectAtIndex:0];
        NSUInteger generation = [[args objectAtIndex:1] unsignedIntegerValue];
        StreamOpenAttempt *attempt = [args objectAtIndex:2];
        NSError *error = nil;
        BOOL opened = [self openStream:urlString attempt:attempt error:&error];

        if (attempt->cancelled) {
            // Abandoned while connecting: the player has moved on and owns
            // nothing of this attempt any more
            return;
        }
        if (!opened) {
            _connecting = NO;
            [self postToMain:@selector(mainDidFail:)
                      object:error ?: streamError(-1, @"Cannot open the stream")
                  generation:generation];
            return;
        }

        _decodeErrorCount = 0;
        _clockOrigin = monotonicSeconds() - _position;
        _isPlaying = YES;
        _connecting = NO;
        [self postToMain:@selector(mainDidStart:) object:nil generation:generation];
        [self playbackLoop];
    }
}

// Opens the stream and its decoders; the caller has closed the previous one.
// The network part works on a context of its own, which becomes the
// player's only if the attempt has not been cancelled meanwhile.
- (BOOL)openStream:(NSString *)urlString
           attempt:(StreamOpenAttempt *)attempt
             error:(NSError **)error
{
    const char *url = [urlString UTF8String];
    AVFormatContext *fmtCtx = avformat_alloc_context();
    if (!fmtCtx) {
        if (error) *error = streamError(1, @"Failed to allocate format context");
        return NO;
    }
    fmtCtx->interrupt_callback.callback = interruptCallback;
    fmtCtx->interrupt_callback.opaque = attempt;

    // Network options; ignored for local files
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "timeout", "15000000", 0);   // 15 s timeout
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_delay_max", "5", 0);
    av_dict_set(&opts, "icy", "1", 0);               // ICY metadata (StreamTitle)

    int ret = avformat_open_input(&fmtCtx, url, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        char errBuf[256];
        av_strerror(ret, errBuf, sizeof(errBuf));
        NSLog(@"[StreamPlayer] cannot open %@: %s", urlString, errBuf);
        if (error) {
            *error = streamError(ret, [NSString stringWithFormat:@"%s", errBuf]);
        }
        return NO;   // avformat_open_input frees the context on failure
    }

    ret = avformat_find_stream_info(fmtCtx, NULL);
    if (ret < 0) {
        if (error) *error = streamError(ret, @"The stream format is not recognized");
        avformat_close_input(&fmtCtx);
        return NO;
    }

    @synchronized(self) {
        if (attempt->cancelled) {
            avformat_close_input(&fmtCtx);
            return NO;
        }
        _formatCtx = fmtCtx;
    }

    _totalDuration = (fmtCtx->duration > 0) ? (double)fmtCtx->duration / AV_TIME_BASE : 0.0;
    _streamStart = (fmtCtx->start_time != AV_NOPTS_VALUE)
        ? (double)fmtCtx->start_time / AV_TIME_BASE : 0.0;

    [_lastMetadata release];
    _lastMetadata = [[self formatMetadata] retain];

    [self openAudioStream];
    [self openVideoStream];

    if (_audioStreamIndex < 0 && !_hasVideo) {
        if (error) *error = streamError(2, @"The file contains neither audio nor video");
        [self freeStream];
        return NO;
    }

    _packet = av_packet_alloc();
    if (!_packet) {
        if (error) *error = streamError(6, @"Failed to allocate packet");
        [self freeStream];
        return NO;
    }

    _clockFromWall = (_aoDev == NULL);
    _position = 0.0;
    [self setCurrentURL:urlString];
    return YES;
}

- (void)openAudioStream
{
    AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
    int index = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (index < 0) {
        return;
    }
    AVCodecParameters *par = fmtCtx->streams[index]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) {
        NSLog(@"[StreamPlayer] no decoder for audio codec %d", par->codec_id);
        return;
    }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx || avcodec_parameters_to_context(ctx, par) < 0
        || avcodec_open2(ctx, codec, NULL) < 0) {
        NSLog(@"[StreamPlayer] cannot open audio decoder");
        avcodec_free_context(&ctx);
        return;
    }

    AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;
    SwrContext *swr = NULL;
    if (swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_S16, ctx->sample_rate,
                            &ctx->ch_layout, ctx->sample_fmt, ctx->sample_rate,
                            0, NULL) < 0 || swr_init(swr) < 0) {
        NSLog(@"[StreamPlayer] cannot set up the audio resampler");
        swr_free(&swr);
        avcodec_free_context(&ctx);
        return;
    }

    _audioStreamIndex = index;
    _audioSampleRate = ctx->sample_rate;
    _codecCtx = ctx;
    _swrCtx = swr;
    _frame = av_frame_alloc();

    if (!_usesAudioDevice) {
        return;
    }
    int driver = ao_default_driver_id();
    if (driver < 0) {
        NSLog(@"[StreamPlayer] no audio output driver, playing silently");
        return;
    }
    ao_sample_format aoFmt;
    memset(&aoFmt, 0, sizeof(aoFmt));
    aoFmt.bits = 16;
    aoFmt.channels = 2;
    aoFmt.rate = ctx->sample_rate;
    aoFmt.byte_format = AO_FMT_NATIVE;
    _aoDev = ao_open_live(driver, &aoFmt, NULL);
    if (!_aoDev) {
        NSLog(@"[StreamPlayer] cannot open the audio device, playing silently");
    }
}

- (void)openVideoStream
{
    AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
    int index = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (index < 0) {
        return;
    }
    AVStream *stream = fmtCtx->streams[index];
    // Cover art in audio files is an "attached picture", not video
    if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) {
        return;
    }
    AVCodecParameters *par = stream->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) {
        return;
    }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx || avcodec_parameters_to_context(ctx, par) < 0
        || avcodec_open2(ctx, codec, NULL) < 0) {
        NSLog(@"[StreamPlayer] cannot open video decoder");
        avcodec_free_context(&ctx);
        return;
    }
    // GNUstep draws 32-bit RGBA more reliably than 24-bit RGB
    struct SwsContext *sws = sws_getContext(par->width, par->height, ctx->pix_fmt,
                                            par->width, par->height, AV_PIX_FMT_RGBA,
                                            SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) {
        NSLog(@"[StreamPlayer] cannot set up the video scaler");
        avcodec_free_context(&ctx);
        return;
    }

    _videoStreamIndex = index;
    _videoCodecCtx = ctx;
    _swsCtx = sws;
    _videoWidth = par->width;
    _videoHeight = par->height;
    _videoTimeBase = av_q2d(stream->time_base);
    _rgbLinesize = _videoWidth * 4;
    _rgbBufferSize = av_image_get_buffer_size(AV_PIX_FMT_RGBA, _videoWidth, _videoHeight, 1);
    _rgbBuffer = av_malloc(_rgbBufferSize);
    _videoFrame = av_frame_alloc();
    _hasVideo = YES;
}

- (NSDictionary *)formatMetadata
{
    AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    AVDictionaryEntry *tag = NULL;
    while ((tag = av_dict_get(fmtCtx->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)) != NULL) {
        NSString *key = [NSString stringWithUTF8String:tag->key];
        NSString *val = [NSString stringWithUTF8String:tag->value];
        if (key && val) {
            [meta setObject:val forKey:key];
        }
    }
    return meta;
}

- (void)play
{
    if (_isPlaying && _paused) {
        [_pauseCondition lock];
        _clockOrigin = monotonicSeconds() - _position;
        _paused = NO;
        [_pauseCondition broadcast];
        [_pauseCondition unlock];
        return;
    }
    if (_isPlaying || !_formatCtx) {
        return;
    }

    // A thread that ended at the end of the stream is gone already
    [_playbackThread release];
    _playbackThread = nil;

    _shouldStop = NO;
    _paused = NO;
    _isPlaying = YES;
    _decodeErrorCount = 0;
    _clockOrigin = monotonicSeconds() - _position;

    _playbackThread = [[NSThread alloc] initWithTarget:self
                                              selector:@selector(playbackLoop)
                                                object:nil];
    [_playbackThread start];

    [self notifyStart];
}

- (void)notifyStart
{
    if ([_delegate respondsToSelector:@selector(streamPlayerDidStartPlaying:)]) {
        [_delegate streamPlayerDidStartPlaying:self];
    }
    // Initial ICY metadata, so the UI can show StreamTitle right away
    if ([_lastMetadata count] > 0
        && [_delegate respondsToSelector:@selector(streamPlayer:didUpdateMetadata:)]) {
        [_delegate streamPlayer:self didUpdateMetadata:_lastMetadata];
    }
    if (_hasVideo
        && [_delegate respondsToSelector:@selector(streamPlayer:didDiscoverVideoWithWidth:height:)]) {
        [_delegate streamPlayer:self didDiscoverVideoWithWidth:_videoWidth height:_videoHeight];
    }
}

- (void)pause
{
    if (!_isPlaying || _paused) {
        return;
    }
    [_pauseCondition lock];
    if (_clockFromWall) {
        _position = [self wallClockPosition];
    }
    _paused = YES;
    [_pauseCondition unlock];
}

- (void)seekToTime:(NSTimeInterval)seconds
{
    if (!_formatCtx) {
        return;
    }
    if (seconds < 0.0) {
        seconds = 0.0;
    }
    if (_totalDuration > 0.0 && seconds > _totalDuration) {
        seconds = _totalDuration;
    }

    [_seekLock lock];
    _position = seconds;
    _clockOrigin = monotonicSeconds() - seconds;
    if (_isPlaying) {
        // The playback thread owns the decoders; it seeks before its next read
        _seekTarget = seconds;
    }
    [_seekLock unlock];

    if (!_isPlaying) {
        [self performSeekTo:seconds];
    }
}

- (void)stop
{
    BOOL abandon;
    @synchronized(self) {
        ((StreamOpenAttempt *)_attempt)->cancelled = YES;
        // Not open yet: the thread may be stuck in a host name lookup,
        // which would hold the caller for as long as that takes
        abandon = (_formatCtx == NULL);
    }
    [_pauseCondition lock];
    _shouldStop = YES;
    _paused = NO;
    [_pauseCondition broadcast];
    [_pauseCondition unlock];

    while (!abandon && _playbackThread && ![_playbackThread isFinished]) {
        [NSThread sleepForTimeInterval:0.005];
    }
    [_playbackThread release];
    _playbackThread = nil;
    _isPlaying = NO;
    _connecting = NO;
}

- (void)close
{
    [self stop];
    [self freeStream];
}

// Releases the stream's decoders and device; the playback thread is done
// with them (stopped, or this is that thread giving up during opening).
- (void)freeStream
{

    if (_audioBuffer) {
        free(_audioBuffer);
        _audioBuffer = NULL;
        _audioBufferSize = 0;
    }
    if (_frame) {
        av_frame_free((AVFrame **)&_frame);
    }
    if (_packet) {
        av_packet_free((AVPacket **)&_packet);
    }
    if (_swrCtx) {
        swr_free((SwrContext **)&_swrCtx);
    }
    if (_codecCtx) {
        avcodec_free_context((AVCodecContext **)&_codecCtx);
    }
    if (_formatCtx) {
        avformat_close_input((AVFormatContext **)&_formatCtx);
    }
    if (_aoDev) {
        ao_close((ao_device *)_aoDev);
        _aoDev = NULL;
    }
    if (_videoFrame) {
        av_frame_free((AVFrame **)&_videoFrame);
    }
    if (_swsCtx) {
        sws_freeContext((struct SwsContext *)_swsCtx);
        _swsCtx = NULL;
    }
    if (_rgbBuffer) {
        av_free(_rgbBuffer);
        _rgbBuffer = NULL;
    }
    if (_videoCodecCtx) {
        avcodec_free_context((AVCodecContext **)&_videoCodecCtx);
    }

    _rgbBufferSize = 0;
    _rgbLinesize = 0;
    _audioStreamIndex = -1;
    _videoStreamIndex = -1;
    _hasVideo = NO;
    _videoWidth = 0;
    _videoHeight = 0;
    _decodeErrorCount = 0;
    _position = 0.0;
    _totalDuration = 0.0;
    _streamStart = 0.0;
    _seekTarget = -1.0;
    _framePending = NO;
    [_lastMetadata release];
    _lastMetadata = nil;
    [self setCurrentURL:nil];
}

#pragma mark - Playback thread

- (void)playbackLoop
{
    @autoreleasepool {
        NSUInteger generation = _generation;
        BOOL failed = NO;
        unsigned int packetCount = 0;

        while (!_shouldStop) {
            [self performPendingSeek];

            if (_paused) {
                [_pauseCondition lock];
                while (_paused && !_shouldStop) {
                    [_pauseCondition wait];
                }
                [_pauseCondition unlock];
                continue;   // a seek may have come in while paused
            }

            @autoreleasepool {
                AVPacket *pkt = (AVPacket *)_packet;
                int ret = av_read_frame((AVFormatContext *)_formatCtx, pkt);
                if (ret < 0) {
                    if (_shouldStop) {
                        break;
                    }
                    if (ret == AVERROR_EOF || ret == AVERROR(EAGAIN)) {
                        [self drainDecoders];
                        break;
                    }
                    char errBuf[256];
                    av_strerror(ret, errBuf, sizeof(errBuf));
                    [self postToMain:@selector(mainDidFail:)
                              object:streamError(ret, [NSString stringWithFormat:
                                  @"Error reading stream: %s", errBuf])
                          generation:generation];
                    failed = YES;
                    break;
                }

                if (pkt->stream_index == _audioStreamIndex) {
                    [self decodeAudioPacket:pkt];
                } else if (pkt->stream_index == _videoStreamIndex) {
                    [self decodeVideoPacket:pkt];
                }
                av_packet_unref(pkt);

                // Radio stations change StreamTitle as songs change
                if (++packetCount % 50 == 0) {
                    NSDictionary *meta = [self formatMetadata];
                    if (![_lastMetadata isEqualToDictionary:meta]) {
                        [_lastMetadata release];
                        _lastMetadata = [meta retain];
                        [self postToMain:@selector(mainDidUpdateMetadata:)
                                  object:meta
                              generation:generation];
                    }
                }
            }
        }

        if (!_shouldStop && !failed) {
            // The last packets were decoded a little ahead of time
            if (_clockFromWall) {
                [self waitForMediaTime:_totalDuration > 0 ? _totalDuration : _position
                                  lead:0.0];
                _position = [self wallClockPosition];
            }
            if (_totalDuration > 0.0) {
                _position = _totalDuration;
            }
        }
        BOOL ended = !_shouldStop;
        _isPlaying = NO;
        if (ended && !failed) {
            [self postToMain:@selector(mainDidStop:) object:nil generation:generation];
        }
    }
}

- (void)performPendingSeek
{
    [_seekLock lock];
    double target = _seekTarget;
    _seekTarget = -1.0;
    [_seekLock unlock];
    if (target >= 0.0) {
        [self performSeekTo:target];
        [_seekLock lock];
        if (_seekTarget < 0.0) {
            _clockOrigin = monotonicSeconds() - target;
        }
        [_seekLock unlock];
    }
}

- (void)performSeekTo:(double)seconds
{
    AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
    int64_t ts = (int64_t)((seconds + _streamStart) * AV_TIME_BASE);
    if (av_seek_frame(fmtCtx, -1, ts, AVSEEK_FLAG_BACKWARD) < 0) {
        NSLog(@"[StreamPlayer] seek to %.2f s failed", seconds);
        return;
    }
    if (_codecCtx) {
        avcodec_flush_buffers((AVCodecContext *)_codecCtx);
    }
    if (_videoCodecCtx) {
        avcodec_flush_buffers((AVCodecContext *)_videoCodecCtx);
    }
    _position = seconds;
}

- (BOOL)seekPending
{
    return _seekTarget >= 0.0;
}

// Media time: audio position while the sound device paces playback,
// otherwise the wall clock.
- (double)masterClock
{
    return _clockFromWall ? monotonicSeconds() - _clockOrigin : _position;
}

// Sleeps until the media clock reaches t (minus lead).  Returns early on
// stop, pause and seek so that those take effect at once.
- (void)waitForMediaTime:(double)t lead:(double)lead
{
    if ([self waitWouldBeForABrokenTimestamp:t lead:lead]) {
        return;
    }
    while (!_shouldStop && !_paused && ![self seekPending]) {
        double remaining = t - lead - [self masterClock];
        if (remaining <= 0.0) {
            return;
        }
        [NSThread sleepForTimeInterval:MIN(remaining, 0.01)];
    }
}

// Without a sound device the wait is the only thing that keeps playback at
// its real speed, and decoding is always a few seconds ahead of it, so "far
// ahead of the clock" cannot mean a broken timestamp there; only a time
// beyond the end of the stream can.  A device paces playback itself, and a
// frame far ahead of its position means the sound has stalled - waiting for
// that one would freeze the picture, so it is skipped as before.
- (BOOL)waitWouldBeForABrokenTimestamp:(double)t lead:(double)lead
{
    if (_clockFromWall && _totalDuration > 0.0) {
        return t > _totalDuration + kMaxFrameWait;
    }
    return t - lead - [self masterClock] > kMaxFrameWait;
}

- (double)secondsOfFrame:(AVFrame *)frame timeBase:(double)timeBase
{
    if (frame->best_effort_timestamp == AV_NOPTS_VALUE || timeBase <= 0.0) {
        return -1.0;
    }
    return (double)frame->best_effort_timestamp * timeBase - _streamStart;
}

- (void)decodeAudioPacket:(AVPacket *)pkt
{
    AVCodecContext *ctx = (AVCodecContext *)_codecCtx;
    if (!ctx) {
        return;
    }
    int ret = avcodec_send_packet(ctx, pkt);
    if (ret < 0) {
        [self countDecodeError:ret];
        return;
    }
    [self receiveAudioFrames];
}

- (void)receiveAudioFrames
{
    AVCodecContext *ctx = (AVCodecContext *)_codecCtx;
    AVFrame *frame = (AVFrame *)_frame;
    AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
    double timeBase = av_q2d(fmtCtx->streams[_audioStreamIndex]->time_base);

    while (!_shouldStop && ![self seekPending]) {
        int ret = avcodec_receive_frame(ctx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return;
        }
        if (ret < 0) {
            [self countDecodeError:ret];
            return;
        }
        if (frame->nb_samples <= 0 || _audioSampleRate <= 0) {
            continue;
        }

        double frameLength = (double)frame->nb_samples / _audioSampleRate;
        double start = [self secondsOfFrame:frame timeBase:timeBase];
        if (start < 0.0) {
            start = _position;
        }
        double end = start + frameLength;
        // After a seek decoding restarts at the keyframe before the target
        if (end <= _position - 0.05 && !_clockFromWall) {
            continue;
        }

        if (_aoDev) {
            [self playSamplesOfFrame:frame];
            _position = end;
        } else {
            [self waitForMediaTime:end lead:kWallClockLead];
        }
    }
}

- (void)playSamplesOfFrame:(AVFrame *)frame
{
    int outBytes = av_samples_get_buffer_size(NULL, 2, frame->nb_samples, AV_SAMPLE_FMT_S16, 1);
    if (outBytes <= 0) {
        return;
    }
    if (_audioBufferSize < outBytes) {
        free(_audioBuffer);
        _audioBuffer = malloc(outBytes);
        _audioBufferSize = _audioBuffer ? outBytes : 0;
        if (!_audioBuffer) {
            return;
        }
    }

    uint8_t *outPtrs[] = { (uint8_t *)_audioBuffer };
    int converted = swr_convert((SwrContext *)_swrCtx, outPtrs, frame->nb_samples,
                                (const uint8_t **)frame->data, frame->nb_samples);
    if (converted <= 0) {
        return;
    }

    int16_t *samples = (int16_t *)_audioBuffer;
    int sampleCount = converted * 2;  // stereo
    float volume = _muted ? 0.0f : _volume;
    // The fade is interpolated across the frame, so it has no steps
    double now = monotonicSeconds();
    float gainStart = volume * [self fadeGainAt:now];
    float gainEnd = volume * [self fadeGainAt:now + (double)converted / _audioSampleRate];
    int i;
    for (i = 0; i < sampleCount; i++) {
        float gain = gainStart + (gainEnd - gainStart) * (float)(i / 2) / (float)converted;
        samples[i] = (int16_t)(samples[i] * gain);
    }
    ao_play((ao_device *)_aoDev, (char *)_audioBuffer, sampleCount * (int)sizeof(int16_t));
}

- (void)decodeVideoPacket:(AVPacket *)pkt
{
    AVCodecContext *ctx = (AVCodecContext *)_videoCodecCtx;
    if (!ctx) {
        return;
    }
    if (avcodec_send_packet(ctx, pkt) < 0) {
        return;
    }
    [self receiveVideoFrames];
}

- (void)receiveVideoFrames
{
    AVCodecContext *ctx = (AVCodecContext *)_videoCodecCtx;
    AVFrame *frame = (AVFrame *)_videoFrame;

    while (!_shouldStop && ![self seekPending]) {
        int ret = avcodec_receive_frame(ctx, frame);
        if (ret < 0) {
            return;
        }
        double pts = [self secondsOfFrame:frame timeBase:_videoTimeBase];

        if (_audioStreamIndex < 0 && pts >= 0.0) {
            // Video-only: the frames are the position
            if (pts < _position - 0.05) {
                continue;   // before the seek target
            }
        } else if (pts >= 0.0 && pts < _position - 0.1 && _clockFromWall) {
            continue;
        }

        // With the sound device the audio already paces the thread; the
        // frame then shows as soon as it is decoded.
        if (pts >= 0.0 && _clockFromWall) {
            [self waitForMediaTime:pts lead:0.0];
            if (_shouldStop || [self seekPending]) {
                return;
            }
        }
        if (_audioStreamIndex < 0 && pts >= 0.0 && !_clockFromWall) {
            _position = pts;
        }
        [self deliverVideoFrame:frame];
    }
}

- (void)deliverVideoFrame:(AVFrame *)frame
{
    if (_framePending
        || ![_delegate respondsToSelector:@selector(streamPlayer:didDecodeVideoFrameData:width:height:)]) {
        return;
    }
    uint8_t *dstData[1] = { _rgbBuffer };
    int dstLinesize[1] = { _rgbLinesize };
    sws_scale((struct SwsContext *)_swsCtx,
              (const uint8_t *const *)frame->data, frame->linesize,
              0, _videoHeight, dstData, dstLinesize);

    NSData *data = [NSData dataWithBytes:_rgbBuffer length:_rgbBufferSize];
    NSArray *payload = @[data, @(_videoWidth), @(_videoHeight)];
    _framePending = YES;
    [self postToMain:@selector(mainDidDecodeVideoFrame:) object:payload generation:_generation];
}

- (void)drainDecoders
{
    if (_codecCtx) {
        avcodec_send_packet((AVCodecContext *)_codecCtx, NULL);
        [self receiveAudioFrames];
    }
    if (_videoCodecCtx) {
        avcodec_send_packet((AVCodecContext *)_videoCodecCtx, NULL);
        [self receiveVideoFrames];
    }
}

- (void)countDecodeError:(int)code
{
    // A few broken packets are normal in network streams; many mean the
    // stream is unplayable.
    if (++_decodeErrorCount > 10) {
        _shouldStop = YES;
        [self postToMain:@selector(mainDidFail:)
                  object:streamError(code, @"Too many decode errors")
              generation:_generation];
    }
}

#pragma mark - Delegate delivery on the main thread

- (void)postToMain:(SEL)selector object:(id)object generation:(NSUInteger)generation
{
    NSArray *message = object ? @[@(generation), object] : @[@(generation)];
    // Also in the modal and tracking modes, so video keeps running while a
    // dialog is up or the position slider is dragged
    [self performSelectorOnMainThread:selector
                           withObject:message
                        waitUntilDone:NO
                                modes:@[NSDefaultRunLoopMode,
                                        @"NSModalPanelRunLoopMode",
                                        @"NSEventTrackingRunLoopMode"]];
}

- (BOOL)isCurrentMessage:(NSArray *)message
{
    return [[message objectAtIndex:0] unsignedIntegerValue] == _generation;
}

- (void)mainDidStop:(NSArray *)message
{
    if ([self isCurrentMessage:message]
        && [_delegate respondsToSelector:@selector(streamPlayerDidStop:)]) {
        [_delegate streamPlayerDidStop:self];
    }
}

- (void)mainDidStart:(NSArray *)message
{
    if ([self isCurrentMessage:message]) {
        [self notifyStart];
    }
}

- (void)mainDidFail:(NSArray *)message
{
    if ([self isCurrentMessage:message]
        && [_delegate respondsToSelector:@selector(streamPlayer:didFailWithError:)]) {
        [_delegate streamPlayer:self didFailWithError:[message objectAtIndex:1]];
    }
}

- (void)mainDidUpdateMetadata:(NSArray *)message
{
    if ([self isCurrentMessage:message]
        && [_delegate respondsToSelector:@selector(streamPlayer:didUpdateMetadata:)]) {
        [_delegate streamPlayer:self didUpdateMetadata:[message objectAtIndex:1]];
    }
}

- (void)mainDidDecodeVideoFrame:(NSArray *)message
{
    _framePending = NO;
    if (![self isCurrentMessage:message]) {
        return;
    }
    NSArray *payload = [message objectAtIndex:1];
    [_delegate streamPlayer:self
    didDecodeVideoFrameData:[payload objectAtIndex:0]
                      width:[[payload objectAtIndex:1] intValue]
                     height:[[payload objectAtIndex:2] intValue]];
}

@end
