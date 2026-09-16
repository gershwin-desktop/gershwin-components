/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StreamPlayer.h"

#include <ao/ao.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

@implementation StreamPlayer

@synthesize delegate = _delegate;
@synthesize volume = _volume;
@synthesize muted = _muted;
@synthesize currentURL = _currentURL;
@synthesize hasVideo = _hasVideo;
@synthesize videoWidth = _videoWidth;
@synthesize videoHeight = _videoHeight;

+ (instancetype)sharedPlayer
{
    static StreamPlayer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _volume = 1.0f;
        _muted = NO;
        _isPlaying = NO;
        _shouldStop = NO;
        _paused = NO;
        _pauseCondition = [[NSCondition alloc] init];
        _audioStreamIndex = -1;
        _decodeErrorCount = 0;
        _accumulatedAudioTime = 0.0;
        _totalDuration = 0.0;
        _generation = 0;
        _videoTimeBase = 0.0;
        _firstFramePts = 0.0;
        _hasFirstFramePts = NO;
        _lastFramePts = 0.0;
        _frameDuration = 0.0;
        _lastMetadata = nil;
        _metadataCheckCounter = 0;

        ao_initialize();
    }
    return self;
}

- (void)dealloc
{
    [self close];
    [_pauseCondition release];
    ao_shutdown();
    [super dealloc];
}

#pragma mark - Properties

- (BOOL)isPlaying
{
    @synchronized(self) {
        return _isPlaying;
    }
}

- (void)setVolume:(float)volume
{
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    _volume = volume;
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

- (NSTimeInterval)currentTime
{
    return _accumulatedAudioTime;
}

- (NSTimeInterval)duration
{
    return _totalDuration;
}

#pragma mark - Public API

- (BOOL)openURL:(NSString *)urlString error:(NSError **)error
{
    if (urlString == nil || [urlString length] == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"StreamPlayer"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"URL is nil or empty"}];
        }
        return NO;
    }

    @synchronized(self) {
        // Bump generation so any stale async delegate callbacks
        // from the previous stream are dropped.
        _generation++;
        _naturalStop = NO;
        [self close];

        const char *url = [urlString UTF8String];
        if (!url) {
            if (error) {
                *error = [NSError errorWithDomain:@"StreamPlayer"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL string encoding"}];
            }
            return NO;
        }

        // ---- Open stream with FFmpeg ---- //
        _formatCtx = avformat_alloc_context();
        if (!_formatCtx) {
            if (error) {
                *error = [NSError errorWithDomain:@"StreamPlayer"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to allocate format context"}];
            }
            return NO;
        }

        // Set network options for streaming
        AVDictionary *opts = NULL;
        av_dict_set(&opts, "timeout", "15000000", 0);   // 15 s timeout
        av_dict_set(&opts, "reconnect", "1", 0);
        av_dict_set(&opts, "reconnect_streamed", "1", 0);
        av_dict_set(&opts, "reconnect_delay_max", "5", 0);
        av_dict_set(&opts, "icy", "1", 0);               // Enable ICY metadata parsing

        int ret = avformat_open_input((AVFormatContext **)&_formatCtx, url, NULL, &opts);
        av_dict_free(&opts);

        if (ret < 0) {
            char errBuf[256];
            av_strerror(ret, errBuf, sizeof(errBuf));
            NSLog(@"[StreamPlayer] avformat_open_input failed: %s (code %d)", errBuf, ret);
            if (error) {
                *error = [NSError errorWithDomain:@"StreamPlayer"
                                             code:ret
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"Failed to open stream: %s", errBuf]}];
            }
            if (_formatCtx) {
                avformat_close_input((AVFormatContext **)&_formatCtx);
                _formatCtx = NULL;
            }
            return NO;
        }
        NSLog(@"[StreamPlayer] Opened stream for URL: %s", url);

        // Find stream info
        ret = avformat_find_stream_info((AVFormatContext *)_formatCtx, NULL);
        if (ret < 0) {
            char errBuf[256]; av_strerror(ret, errBuf, sizeof(errBuf));
            NSLog(@"[StreamPlayer] avformat_find_stream_info failed: %s", errBuf);
            if (error) {
                *error = [NSError errorWithDomain:@"StreamPlayer"
                                             code:ret
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to find stream info"}];
            }
            avformat_close_input((AVFormatContext **)&_formatCtx);
            _formatCtx = NULL;
            return NO;
        }

        // Read total duration from format context
        {
            AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
            _totalDuration = (fmtCtx->duration > 0) ?
                (double)fmtCtx->duration / AV_TIME_BASE : 0.0;
        }

        // Read initial ICY metadata
        {
            AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
            AVDictionaryEntry *tag = NULL;
            NSMutableDictionary *meta = [NSMutableDictionary dictionary];
            while ((tag = av_dict_get(fmtCtx->metadata, "", tag,
                                      AV_DICT_IGNORE_SUFFIX)) != NULL) {
                NSString *key = [NSString stringWithUTF8String: tag->key];
                NSString *val = [NSString stringWithUTF8String: tag->value];
                if (key && val) {
                    [meta setObject:val forKey:key];
                }
                NSLog(@"[StreamPlayer] ICY metadata: %s = %s", tag->key, tag->value);
            }
            [_lastMetadata release];
            _lastMetadata = [meta retain];
        }

        // Find audio stream
        AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
        _audioStreamIndex = -1;
        for (unsigned int i = 0; i < fmtCtx->nb_streams; i++) {
            if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                _audioStreamIndex = i;
                break;
            }
        }

        if (_audioStreamIndex < 0) {
            NSLog(@"[StreamPlayer] No audio stream found - video-only mode");
        } else {
            // Set up audio codec
            AVCodecParameters *codecPar = fmtCtx->streams[_audioStreamIndex]->codecpar;
            NSLog(@"[StreamPlayer] Audio codec ID: %d, sample rate: %d, channels: %d",
                  codecPar->codec_id, codecPar->sample_rate, codecPar->ch_layout.nb_channels);

            const AVCodec *codec = avcodec_find_decoder(codecPar->codec_id);
            if (!codec) {
                NSLog(@"[StreamPlayer] Audio codec not found - video-only mode");
                _audioStreamIndex = -1;
            } else {
                _codecCtx = avcodec_alloc_context3(codec);
                if (_codecCtx) {
                    avcodec_parameters_to_context((AVCodecContext *)_codecCtx, codecPar);
                    ret = avcodec_open2((AVCodecContext *)_codecCtx, codec, NULL);
                    if (ret < 0) {
                        NSLog(@"[StreamPlayer] Failed to open audio codec - video-only mode");
                        avcodec_free_context((AVCodecContext **)&_codecCtx);
                        _codecCtx = NULL;
                        _audioStreamIndex = -1;
                    }
                } else {
                    _audioStreamIndex = -1;
                }
            }
        }

        // ---- Find video stream and set up video decoder ---- //
        _videoStreamIndex = -1;
        _hasVideo = NO;
        _videoWidth = 0;
        _videoHeight = 0;
        for (unsigned int i = 0; i < fmtCtx->nb_streams; i++) {
            if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                _videoStreamIndex = i;
                break;
            }
        }

        if (_videoStreamIndex >= 0) {
            AVCodecParameters *videoCodecPar = fmtCtx->streams[_videoStreamIndex]->codecpar;
            const AVCodec *videoCodec = avcodec_find_decoder(videoCodecPar->codec_id);
            if (videoCodec) {
                _videoCodecCtx = avcodec_alloc_context3(videoCodec);
                if (_videoCodecCtx) {
                    avcodec_parameters_to_context((AVCodecContext *)_videoCodecCtx,
                                                   videoCodecPar);
                    ret = avcodec_open2((AVCodecContext *)_videoCodecCtx, videoCodec, NULL);
                    if (ret >= 0) {
                        _videoWidth = videoCodecPar->width;
                        _videoHeight = videoCodecPar->height;
                        _hasVideo = YES;

                        // Store video stream time_base for PTS-to-seconds conversion
                        AVFormatContext *fmtCtx2 = (AVFormatContext *)_formatCtx;
                        AVStream *vStream = fmtCtx2->streams[_videoStreamIndex];
                        _videoTimeBase = av_q2d(vStream->time_base);

                        // Approximate frame duration from codec or stream frame rate
                        AVCodecContext *vCtxForFps = (AVCodecContext *)_videoCodecCtx;
                        if (vCtxForFps->framerate.num > 0 && vCtxForFps->framerate.den > 0) {
                            _frameDuration = (double)vCtxForFps->framerate.den / (double)vCtxForFps->framerate.num;
                        } else if (vStream->r_frame_rate.num > 0 && vStream->r_frame_rate.den > 0) {
                            _frameDuration = (double)vStream->r_frame_rate.den / (double)vStream->r_frame_rate.num;
                        } else {
                            _frameDuration = 0.0;
                        }

                        NSLog(@"[StreamPlayer] Video stream: %dx%d, codec: %d, time_base=%f, frame_dur=%f",
                              _videoWidth, _videoHeight, videoCodecPar->codec_id,
                              _videoTimeBase, _frameDuration);

                        // Set up swscale for RGBA conversion (GNUstep handles
                        // 32-bit RGBA more reliably than 24-bit RGB)
                        AVCodecContext *vCtx = (AVCodecContext *)_videoCodecCtx;
                        _swsCtx = sws_getContext(_videoWidth, _videoHeight, vCtx->pix_fmt,
                                                  _videoWidth, _videoHeight, AV_PIX_FMT_RGBA,
                                                  SWS_BILINEAR, NULL, NULL, NULL);
                        if (_swsCtx) {
                            _rgbLinesize = _videoWidth * 4;
                            _rgbBufferSize = av_image_get_buffer_size(AV_PIX_FMT_RGBA,
                                                                      _videoWidth,
                                                                      _videoHeight, 1);
                            _rgbBuffer = av_malloc(_rgbBufferSize);
                            _videoFrame = av_frame_alloc();
                        } else {
                            NSLog(@"[StreamPlayer] Failed to create swscale context");
                        }
                    } else {
                        NSLog(@"[StreamPlayer] Failed to open video codec");
                        avcodec_free_context((AVCodecContext **)&_videoCodecCtx);
                        _videoCodecCtx = NULL;
                    }
                }
            }
        }
        if (!_hasVideo) {
            NSLog(@"[StreamPlayer] No video stream found, audio only");
        }

        // Set up resampler (convert to stereo S16) - only if we have audio
        if (_audioStreamIndex >= 0 && _codecCtx) {
            AVCodecContext *codecCtx = (AVCodecContext *)_codecCtx;
            AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;

            ret = swr_alloc_set_opts2((SwrContext **)&_swrCtx,
                                      &outLayout, AV_SAMPLE_FMT_S16, codecCtx->sample_rate,
                                      &codecCtx->ch_layout, codecCtx->sample_fmt, codecCtx->sample_rate,
                                      0, NULL);
            if (ret < 0 || swr_init((SwrContext *)_swrCtx) < 0) {
                NSLog(@"[StreamPlayer] Failed to initialize resampler - audio disabled");
                _swrCtx = NULL;
            }
        }

        // Allocate frame and packet
        if (_audioStreamIndex >= 0) {
            _frame = av_frame_alloc();
        }
        _packet = av_packet_alloc();
        if (!_packet) {
            if (error) {
                *error = [NSError errorWithDomain:@"StreamPlayer"
                                             code:6
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to allocate packet"}];
            }
            [self close];
            return NO;
        }

        // ---- Set up libao - only if we have audio ---- //
        if (_audioStreamIndex >= 0 && _codecCtx && _swrCtx) {
            AVCodecContext *codecCtx = (AVCodecContext *)_codecCtx;
            int driver = ao_default_driver_id();
            if (driver >= 0) {
                ao_sample_format aoFmt;
                memset(&aoFmt, 0, sizeof(ao_sample_format));
                aoFmt.bits = 16;
                aoFmt.channels = 2;
                aoFmt.rate = codecCtx->sample_rate;
                aoFmt.byte_format = AO_FMT_NATIVE;

                _aoDev = ao_open_live(driver, &aoFmt, NULL);
                if (!_aoDev) {
                    NSLog(@"[StreamPlayer] Failed to open audio device - video-only mode");
                }
            } else {
                NSLog(@"[StreamPlayer] No audio output driver - video-only mode");
            }
        }

        [self setCurrentURL:urlString];
        return YES;
    }
}

- (void)play
{
    // Resume from paused state
    if (_isPlaying && _paused) {
        _paused = NO;
        [_pauseCondition signal];
        return;
    }

    if (_isPlaying || !_formatCtx) {
        return;
    }

    _shouldStop = NO;
    _paused = NO;
    _isPlaying = YES;
    _decodeErrorCount = 0;

    _playbackThread = [[NSThread alloc] initWithTarget:self
                                              selector:@selector(playbackLoop)
                                                object:nil];
    [_playbackThread start];

    if (_delegate != nil && [_delegate respondsToSelector:@selector(streamPlayerDidStartPlaying:)]) {
        [_delegate streamPlayerDidStartPlaying:self];
    }

    // Send initial ICY metadata immediately so the UI can show StreamTitle, icy-url, etc.
    if (_lastMetadata && [_lastMetadata count] > 0 &&
        _delegate != nil && [_delegate respondsToSelector:@selector(streamPlayer:didUpdateMetadata:)]) {
        [_delegate streamPlayer:self didUpdateMetadata:_lastMetadata];
    }

    // Notify delegate of video dimensions
    if (_hasVideo &&
        _delegate != nil && [_delegate respondsToSelector:@selector(streamPlayer:didDiscoverVideoWithWidth:height:)]) {
        [_delegate streamPlayer:self didDiscoverVideoWithWidth:_videoWidth
                         height:_videoHeight];
    }
}

- (void)pause
{
    _paused = YES;
}

- (void)stop
{
    @synchronized(self) {
        if (!_isPlaying) {
            return;
        }
        _paused = NO;         // unblock paused thread
        [_pauseCondition signal];
        _shouldStop = YES;
    }

    // Wait for playback thread to finish
    while (_playbackThread && ![_playbackThread isFinished]) {
        [NSThread sleepForTimeInterval:0.01];
    }

    [_playbackThread release];
    _playbackThread = nil;

    _isPlaying = NO;

    // Only dispatch delegate for natural EOF, not manual stop.
    // PlayerController handles UI cleanup directly when it calls stop: manually.
    if (_naturalStop) {
        _naturalStop = NO;
        if (_delegate != nil && [_delegate respondsToSelector:@selector(streamPlayerDidStop:)]) {
            NSUInteger gen = _generation;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_generation != gen) return;  // stale - a new stream opened
                [self->_delegate streamPlayerDidStop:self];
            });
        }
    }
}

- (void)close
{
    [self stop];

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

    // Free video resources
    if (_videoFrame) {
        av_frame_free((AVFrame **)&_videoFrame);
        _videoFrame = NULL;
    }
    if (_swsCtx) {
        sws_freeContext((struct SwsContext *)_swsCtx);
        _swsCtx = NULL;
    }
    if (_rgbBuffer) {
        av_free(_rgbBuffer);
        _rgbBuffer = NULL;
        _rgbBufferSize = 0;
        _rgbLinesize = 0;
    }
    if (_videoCodecCtx) {
        avcodec_free_context((AVCodecContext **)&_videoCodecCtx);
        _videoCodecCtx = NULL;
    }

    _audioStreamIndex = -1;
    _videoStreamIndex = -1;
    _hasVideo = NO;
    _videoWidth = 0;
    _videoHeight = 0;
    _videoCodecCtx = NULL;
    _videoFrame = NULL;
    _swsCtx = NULL;
    _rgbBuffer = NULL;
    _rgbBufferSize = 0;
    _rgbLinesize = 0;
    _decodeErrorCount = 0;
    _accumulatedAudioTime = 0.0;
    _totalDuration = 0.0;
    _videoTimeBase = 0.0;
    _firstFramePts = 0.0;
    _hasFirstFramePts = NO;
    _lastFramePts = 0.0;
    _frameDuration = 0.0;
    [_lastMetadata release];
    _lastMetadata = nil;
    _metadataCheckCounter = 0;
    [self setCurrentURL:nil];
}

#pragma mark - Playback Loop

- (void)playbackLoop
{
    @autoreleasepool {
        // Need at least a format context and a packet to decode anything.
        // Audio components (_codecCtx/_swrCtx/_aoDev) may be NULL for
        // video-only files - that's fine, we'll just skip audio packets.
        if (!_formatCtx || !_packet) {
            _isPlaying = NO;
            return;
        }

        int frameCount = 0;

        while (!_shouldStop) {
            if (!_formatCtx) break;

            // Check pause state before each read - avoid blocking I/O while paused
            if (_paused) {
                [_pauseCondition lock];
                while (_paused && !_shouldStop) {
                    [_pauseCondition wait];
                }
                [_pauseCondition unlock];
                if (_shouldStop) break;
            }

            @autoreleasepool {
                AVPacket *pkt = (AVPacket *)_packet;
                int ret = av_read_frame((AVFormatContext *)_formatCtx, pkt);
                if (ret < 0) {
                    if (ret == AVERROR_EOF || ret == AVERROR(EAGAIN)) {
                        // Drain remaining frames from decoders before stopping
                        [self drainDecoders];
                        break;
                    }
                    // Error reading frame
                    if (_delegate != nil && [_delegate respondsToSelector:@selector(streamPlayer:didFailWithError:)]) {
                        NSError *err = [NSError errorWithDomain:@"StreamPlayer"
                                                           code:ret
                                                       userInfo:@{NSLocalizedDescriptionKey: @"Error reading stream"}];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self->_delegate streamPlayer:self didFailWithError:err];
                        });
                    }
                    break;
                }

                if (pkt->stream_index == _audioStreamIndex) {
                    [self decodePacket];
                    frameCount++;
                    if (frameCount == 1) {
                        NSLog(@"[StreamPlayer] First audio frame decoded");
                    }
                } else if (_hasVideo && pkt->stream_index == _videoStreamIndex) {
                    [self decodeVideoPacket];
                }

                av_packet_unref(pkt);

                // Poll ICY metadata every ~50 frames for changes
                if (frameCount % 50 == 0 && _formatCtx) {
                    AVFormatContext *fmtCtx = (AVFormatContext *)_formatCtx;
                    AVDictionaryEntry *tag = NULL;
                    NSMutableDictionary *currentMeta = [NSMutableDictionary dictionary];
                    while ((tag = av_dict_get(fmtCtx->metadata, "", tag,
                                              AV_DICT_IGNORE_SUFFIX)) != NULL) {
                        NSString *key = [NSString stringWithUTF8String: tag->key];
                        NSString *val = [NSString stringWithUTF8String: tag->value];
                        if (key && val) {
                            [currentMeta setObject:val forKey:key];
                        }
                    }

                    if (![_lastMetadata isEqualToDictionary:currentMeta]) {
                        [_lastMetadata release];
                        _lastMetadata = [currentMeta retain];
                        if (_delegate != nil &&
                            [_delegate respondsToSelector:@selector(streamPlayer:didUpdateMetadata:)]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self->_delegate streamPlayer:self
                                            didUpdateMetadata:currentMeta];
                            });
                        }
                    }
                }
            }
        }

        _isPlaying = NO;
        _naturalStop = YES;

        if (_delegate != nil && [_delegate respondsToSelector:@selector(streamPlayerDidStop:)]) {
            NSUInteger gen = _generation;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_generation != gen) return;  // stale - a new stream started
                [self->_delegate streamPlayerDidStop:self];
            });
        }
    }
}
- (void)decodePacket
{
    if (!_codecCtx || !_swrCtx || !_aoDev || !_packet) {
        return;
    }

    AVCodecContext *codecCtx = (AVCodecContext *)_codecCtx;
    SwrContext *swrCtx = (SwrContext *)_swrCtx;
    ao_device *aoDev = (ao_device *)_aoDev;
    AVPacket *pkt = (AVPacket *)_packet;
    AVFrame *frame = (AVFrame *)_frame;

    int ret = avcodec_send_packet(codecCtx, pkt);
    if (ret < 0) {
        _decodeErrorCount++;
        if (_decodeErrorCount > 10) {
            _shouldStop = YES;
            NSError *err = [NSError errorWithDomain:@"StreamPlayer"
                                               code:ret
                                           userInfo:@{NSLocalizedDescriptionKey: @"Too many decode errors"}];
            [self performSelectorOnMainThread:@selector(notifyDelegateOfFailure:)
                                   withObject:err
                                waitUntilDone:NO];
        }
        return;
    }

    while (ret >= 0) {
        ret = avcodec_receive_frame(codecCtx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            _decodeErrorCount++;
            if (_decodeErrorCount > 10) {
                _shouldStop = YES;
                if (_delegate != nil && [_delegate respondsToSelector:@selector(streamPlayer:didFailWithError:)]) {
                    NSError *err = [NSError errorWithDomain:@"StreamPlayer"
                                                       code:ret
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Too many decode errors"}];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self->_delegate streamPlayer:self didFailWithError:err];
                    });
                }
            }
            break;
        }

        if (!frame || frame->nb_samples <= 0) {
            continue;
        }

        // Calculate output size
        int outSamples = frame->nb_samples;
        int outBytes = av_samples_get_buffer_size(NULL, 2, outSamples, AV_SAMPLE_FMT_S16, 1);
        if (outBytes <= 0) {
            continue;
        }

        // Ensure buffer is large enough
        if (_audioBufferSize < outBytes) {
            if (_audioBuffer) {
                free(_audioBuffer);
            }
            _audioBuffer = malloc(outBytes);
            if (_audioBuffer) {
                _audioBufferSize = outBytes;
            } else {
                _audioBufferSize = 0;
                continue;
            }
        }

        uint8_t *outPtrs[] = { (uint8_t *)_audioBuffer };

        int convertedSamples = swr_convert(swrCtx, outPtrs, outSamples,
                                           (const uint8_t **)frame->data, outSamples);
        if (convertedSamples <= 0) {
            continue;
        }

        // Apply volume
        int16_t *samples = (int16_t *)_audioBuffer;
        int sampleCount = convertedSamples * 2;  // stereo

        float effectiveVolume = _muted ? 0.0f : _volume;

        for (int i = 0; i < sampleCount; i++) {
            samples[i] = (int16_t)(samples[i] * effectiveVolume);
        }

        // Play audio via libao
        ao_play(aoDev, (char *)_audioBuffer, convertedSamples * 2 * (int)sizeof(int16_t));

        // Track playback position
        _accumulatedAudioTime += (double)convertedSamples / codecCtx->sample_rate;
    }
}

- (void)drainDecoders
{
    // Drain audio decoder - flush any buffered frames
    if (_codecCtx) {
        AVCodecContext *codecCtx = (AVCodecContext *)_codecCtx;
        avcodec_send_packet(codecCtx, NULL);
        while (1) {
            AVFrame *frame = (AVFrame *)_frame;
            int ret = avcodec_receive_frame(codecCtx, frame);
            if (ret < 0) break;
            if (!frame || frame->nb_samples <= 0) continue;

            int outSamples = frame->nb_samples;
            int outBytes = av_samples_get_buffer_size(NULL, 2, outSamples, AV_SAMPLE_FMT_S16, 1);
            if (outBytes <= 0) continue;

            if (_audioBufferSize < outBytes) {
                if (_audioBuffer) free(_audioBuffer);
                _audioBuffer = malloc(outBytes);
                _audioBufferSize = outBytes;
            }
            if (!_audioBuffer) { _audioBufferSize = 0; continue; }

            uint8_t *outPtrs[] = { (uint8_t *)_audioBuffer };
            SwrContext *swrCtx = (SwrContext *)_swrCtx;
            int convertedSamples = swr_convert(swrCtx, outPtrs, outSamples,
                                               (const uint8_t **)frame->data, outSamples);
            if (convertedSamples <= 0) continue;

            int16_t *samples = (int16_t *)_audioBuffer;
            int sampleCount = convertedSamples * 2;
            float effectiveVolume = _muted ? 0.0f : _volume;
            for (int i = 0; i < sampleCount; i++) {
                samples[i] = (int16_t)(samples[i] * effectiveVolume);
            }

            ao_device *aoDev = (ao_device *)_aoDev;
            ao_play(aoDev, (char *)_audioBuffer, convertedSamples * 2 * (int)sizeof(int16_t));
            _accumulatedAudioTime += (double)convertedSamples / codecCtx->sample_rate;
        }
    }

    // Drain video decoder
    if (_videoCodecCtx && _hasVideo) {
        AVCodecContext *vCtx = (AVCodecContext *)_videoCodecCtx;
        avcodec_send_packet(vCtx, NULL);
        while (1) {
            AVFrame *frame = (AVFrame *)_videoFrame;
            int ret = avcodec_receive_frame(vCtx, frame);
            if (ret < 0) break;

            uint8_t *dstData[1] = { _rgbBuffer };
            int dstLinesize[1] = { _rgbLinesize };
            sws_scale((struct SwsContext *)_swsCtx,
                      (const uint8_t *const *)frame->data, frame->linesize,
                      0, _videoHeight,
                      dstData, dstLinesize);

            if (_delegate && [_delegate respondsToSelector:
                    @selector(streamPlayer:didDecodeVideoFrameData:width:height:)]) {
                NSData *data = [[NSData alloc] initWithBytes:_rgbBuffer length:_rgbBufferSize];
                int w = _videoWidth;
                int h = _videoHeight;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_delegate streamPlayer:self
                         didDecodeVideoFrameData:data
                                           width:w
                                          height:h];
                    [data release];
                });
            }
        }
    }
}

- (void)decodeVideoPacket
{
    if (!_videoCodecCtx || !_swsCtx || !_videoFrame || !_rgbBuffer) {
        return;
    }

    AVCodecContext *codecCtx = (AVCodecContext *)_videoCodecCtx;
    AVPacket *pkt = (AVPacket *)_packet;

    int ret = avcodec_send_packet(codecCtx, pkt);
    if (ret < 0) return;

    while (ret >= 0) {
        ret = avcodec_receive_frame(codecCtx, (AVFrame *)_videoFrame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return;
        if (ret < 0) return;

        AVFrame *frame = (AVFrame *)_videoFrame;

        // Convert to RGBA (4 bytes/pixel)
        uint8_t *dstData[1] = { _rgbBuffer };
        int dstLinesize[1] = { _rgbLinesize };

        sws_scale((struct SwsContext *)_swsCtx,
                  (const uint8_t *const *)frame->data, frame->linesize,
                  0, _videoHeight,
                  dstData, dstLinesize);

        // ---- PTS-based frame pacing (all video) ---- //
        // Applies to ALL video to prevent the decode loop from flooding
        // the main thread with frames at CPU speed.  For video-only files
        // the PTS also drives the playback position; for A+V files the
        // audio ao_play provides the master clock and video PTS is used
        // only for pacing between consecutive frames.

        double pts = 0.0;
        BOOL hasPts = (frame->best_effort_timestamp != AV_NOPTS_VALUE
                       && _videoTimeBase > 0);
        if (hasPts) {
            pts = (double)frame->best_effort_timestamp * _videoTimeBase;
        }

        // Establish first-frame PTS to handle non-zero start offsets
        if (hasPts && !_hasFirstFramePts) {
            _firstFramePts = pts;
            _hasFirstFramePts = YES;
        }

        if (_audioStreamIndex < 0) {
            // Video-only: PTS drives playback position
            if (hasPts) {
                _accumulatedAudioTime = pts - _firstFramePts;
            } else if (_frameDuration > 0.0) {
                _accumulatedAudioTime += _frameDuration;
            }
        }

        // Pace frame dispatch based on PTS interval between consecutive
        // frames - this keeps the decode loop running at real-time rate
        // regardless of whether audio is present.
        if (hasPts && _lastFramePts > 0.0 && pts > _lastFramePts) {
            double sleepTime = pts - _lastFramePts;
            if (sleepTime > 0.0 && sleepTime < 1.0) {
                [NSThread sleepForTimeInterval:sleepTime];
            }
            _lastFramePts = pts;
        } else if (!hasPts && _frameDuration > 0.0) {
            // Fallback: no valid PTS - use frame-rate duration
            if (_audioStreamIndex < 0) {
                _accumulatedAudioTime += _frameDuration;
            }
            [NSThread sleepForTimeInterval:_frameDuration * 0.9];
        }

        // Deliver frame data to delegate on main thread
        if (_delegate && [_delegate respondsToSelector:
                @selector(streamPlayer:didDecodeVideoFrameData:width:height:)]) {
            NSData *data = [[NSData alloc] initWithBytes:_rgbBuffer
                                                  length:_rgbBufferSize];
            int w = _videoWidth;
            int h = _videoHeight;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_delegate streamPlayer:self
                     didDecodeVideoFrameData:data
                                       width:w
                                      height:h];
                [data release];
            });
        }
    }
}

#pragma mark - Delegate Helpers

- (void)notifyDelegateOfFailure:(NSError *)err
{
    if (_delegate != nil && [_delegate respondsToSelector:@selector(streamPlayer:didFailWithError:)]) {
        [_delegate streamPlayer:self didFailWithError:err];
    }
}

@end
