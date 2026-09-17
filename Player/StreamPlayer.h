/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef StreamPlayer_h
#define StreamPlayer_h

#import <Foundation/Foundation.h>

@class StreamPlayer;

@protocol StreamPlayerDelegate <NSObject>
@optional
- (void)streamPlayerDidStartPlaying:(StreamPlayer *)player;
- (void)streamPlayerDidStop:(StreamPlayer *)player;
- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error;
- (void)streamPlayer:(StreamPlayer *)player didUpdateStatus:(NSString *)status;
/// ICY metadata (e.g., StreamTitle) was updated during streaming
- (void)streamPlayer:(StreamPlayer *)player didUpdateMetadata:(NSDictionary *)metadata;
/// A video stream was discovered with the given dimensions (called once at start).
- (void)streamPlayer:(StreamPlayer *)player didDiscoverVideoWithWidth:(int)width
              height:(int)height;
/// A decoded video frame is ready for display. The data is RGB24 (w * h * 3 bytes).
- (void)streamPlayer:(StreamPlayer *)player didDecodeVideoFrameData:(NSData *)rgbData
              width:(int)width height:(int)height;
@end

@protocol StreamPlayerDelegate;

/**
 * StreamPlayer
 *
 * Audio/video stream player using FFmpeg (libavformat/libavcodec/libswresample)
 * and libao. Handles HTTP streaming URLs with progressive decode/playback.
 * Singleton - one instance shared across the application.
 */
@interface StreamPlayer : NSObject
{
@private
    // FFmpeg/libao internals (opaque pointers)
    void *_formatCtx;      // AVFormatContext *
    void *_codecCtx;       // AVCodecContext *
    void *_swrCtx;         // SwrContext *
    void *_frame;          // AVFrame *
    void *_packet;         // AVPacket *
    void *_aoDev;          // ao_device *
    int _audioStreamIndex;

    // Video FFmpeg internals
    int _videoStreamIndex;
    void *_videoCodecCtx;  // AVCodecContext *
    void *_videoFrame;     // AVFrame *
    void *_swsCtx;         // SwsContext *
    uint8_t *_rgbBuffer;
    int _rgbBufferSize;
    int _rgbLinesize;

    // Playback state
    NSThread *_playbackThread;
    BOOL _shouldStop;
    BOOL _isPlaying;
    BOOL _naturalStop;         // Set on natural EOF, cleared on manual stop
    int _decodeErrorCount;

    // Pause support
    BOOL _paused;
    NSCondition *_pauseCondition;

    // Audio buffer
    void *_audioBuffer;
    int _audioBufferSize;

    // Properties
    float _volume;
    BOOL _muted;
    BOOL _hasVideo;
    int _videoWidth;
    int _videoHeight;
    NSString *_currentURL;

    // Delegate (assigned - not retained to avoid cycles)
    id<StreamPlayerDelegate> _delegate;

    // ICY metadata tracking
    NSDictionary *_lastMetadata;
    int _metadataCheckCounter;

    // Position tracking
    double _accumulatedAudioTime;
    double _totalDuration;

    // Video PTS tracking for position and frame pacing
    double _videoTimeBase;      // av_q2d(videoStream->time_base)
    double _firstFramePts;      // first valid frame PTS in seconds (to subtract from start)
    BOOL _hasFirstFramePts;
    double _lastFramePts;       // PTS of last presented frame in seconds
    double _frameDuration;      // approximated frame duration from stream FPS (fallback pacing)

    // Generation counter - incremented each openURL: so stale
    // async delegate callbacks can be detected and dropped.
    NSUInteger _generation;
}

@property (nonatomic, assign) id<StreamPlayerDelegate> delegate;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, assign) float volume;   // 0.0 - 1.0
@property (nonatomic, assign) BOOL muted;
@property (nonatomic, readonly, copy) NSString *currentURL;
/// YES if the stream contains a video track.
@property (nonatomic, readonly) BOOL hasVideo;
/// Width of the video track (0 if no video).
@property (nonatomic, readonly) int videoWidth;
/// Height of the video track (0 if no video).
@property (nonatomic, readonly) int videoHeight;
/// Current playback position in seconds.
@property (nonatomic, readonly) NSTimeInterval currentTime;
/// Total duration in seconds (0 if unknown / indeterminate).
@property (nonatomic, readonly) NSTimeInterval duration;

+ (instancetype)sharedPlayer;

- (BOOL)openURL:(NSString *)urlString error:(NSError **)error;
- (void)play;
- (void)pause;
- (void)stop;
- (void)close;

@end

#endif /* StreamPlayer_h */
