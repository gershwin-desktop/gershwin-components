/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef StreamPlayer_h
#define StreamPlayer_h

#import <Foundation/Foundation.h>

@class StreamPlayer;

/**
 * All delegate messages arrive on the main thread.  Messages that belong to
 * a stream that has since been replaced by -openURL:error: are dropped.
 */
@protocol StreamPlayerDelegate <NSObject>
@optional
- (void)streamPlayerDidStartPlaying:(StreamPlayer *)player;
/// The stream ended by itself (end of file, or the connection ended).
/// Not sent for -stop or -close.
- (void)streamPlayerDidStop:(StreamPlayer *)player;
- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error;
- (void)streamPlayer:(StreamPlayer *)player didUpdateStatus:(NSString *)status;
/// ICY metadata (e.g., StreamTitle) was updated during streaming
- (void)streamPlayer:(StreamPlayer *)player didUpdateMetadata:(NSDictionary *)metadata;
/// A video stream was discovered with the given dimensions (called once at start).
- (void)streamPlayer:(StreamPlayer *)player didDiscoverVideoWithWidth:(int)width
              height:(int)height;
/// A decoded video frame is ready for display. The data is RGBA (w * h * 4 bytes).
- (void)streamPlayer:(StreamPlayer *)player didDecodeVideoFrameData:(NSData *)rgbaData
              width:(int)width height:(int)height;
@end

/**
 * What a media player must offer to be driven by PlayerSession.
 */
@protocol MediaPlayback <NSObject>
- (id<StreamPlayerDelegate>)delegate;
- (void)setDelegate:(id<StreamPlayerDelegate>)delegate;
/// Opens the stream without blocking and plays it; the outcome arrives as
/// -streamPlayerDidStartPlaying: or -streamPlayer:didFailWithError:.
- (void)playURL:(NSString *)urlString;
- (BOOL)isConnecting;
- (void)play;
- (void)pause;
- (void)stop;
- (void)close;
- (void)seekToTime:(NSTimeInterval)seconds;
- (NSTimeInterval)currentTime;
- (NSTimeInterval)duration;
- (BOOL)isPlaying;
- (BOOL)hasVideo;
- (float)volume;
- (void)setVolume:(float)volume;
- (BOOL)muted;
- (void)setMuted:(BOOL)muted;
@end

/**
 * Plays audio and video from files and network streams with FFmpeg, sound
 * through libao.  Playback runs on a thread of its own.
 *
 * Audio sets the pace while it goes to the sound device.  Without one
 * (video-only files, no usable device, or usesAudioDevice NO) the wall
 * clock does, so playback still runs in real time.
 */
@interface StreamPlayer : NSObject <MediaPlayback>
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
    int _audioSampleRate;

    // Video FFmpeg internals
    int _videoStreamIndex;
    void *_videoCodecCtx;  // AVCodecContext *
    void *_videoFrame;     // AVFrame *
    void *_swsCtx;         // SwsContext *
    uint8_t *_rgbBuffer;
    int _rgbBufferSize;
    int _rgbLinesize;
    double _videoTimeBase;

    // Playback state
    NSThread *_playbackThread;
    volatile BOOL _shouldStop;
    BOOL _isPlaying;
    int _decodeErrorCount;
    volatile BOOL _paused;
    volatile BOOL _connecting;
    id _attempt;           // StreamOpenAttempt of the current stream
    NSCondition *_pauseCondition;

    // Position.  The media clock is the playback position in seconds; it
    // is advanced by audio when the sound device paces playback, otherwise
    // by the wall clock from _clockOrigin.
    volatile double _position;
    double _streamStart;
    double _totalDuration;
    double _clockOrigin;
    BOOL _clockFromWall;
    NSLock *_seekLock;
    double _seekTarget;    // < 0: no seek pending

    // Audio buffer
    void *_audioBuffer;
    int _audioBufferSize;

    // Fade: a gain ramp on top of the volume, from _fadeFrom at
    // _fadeStart to _fadeTo after _fadeDuration (monotonic seconds)
    float _fadeFrom;
    float _fadeTo;
    double _fadeStart;
    double _fadeDuration;

    // Properties
    float _volume;
    BOOL _muted;
    BOOL _usesAudioDevice;
    BOOL _hasVideo;
    int _videoWidth;
    int _videoHeight;
    NSString *_currentURL;

    // Delegate (assigned - not retained to avoid cycles)
    id<StreamPlayerDelegate> _delegate;

    // ICY metadata tracking
    NSDictionary *_lastMetadata;

    // Generation counter - incremented by each openURL: so that delegate
    // messages still on their way from the previous stream are dropped.
    volatile NSUInteger _generation;
    // A frame is on its way to the main thread; later frames are dropped
    // instead of piling up behind a slow display.
    volatile BOOL _framePending;
}

@property (nonatomic, assign) id<StreamPlayerDelegate> delegate;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, assign) float volume;   // 0.0 - 1.0
@property (nonatomic, assign) BOOL muted;
/// NO plays silently, paced by the wall clock.  Takes effect at the next
/// -openURL:error:.  Default YES.
@property (nonatomic, assign) BOOL usesAudioDevice;
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

/// Open a stream URL (http, https, rtsp, file path, etc.)
- (BOOL)openURL:(NSString *)urlString error:(NSError **)error;
/// Opens the stream on the playback thread and plays it; returns at once.
/// The delegate hears -streamPlayerDidStartPlaying: or
/// -streamPlayer:didFailWithError: when the stream is open or cannot be.
/// -close (or another stream) abandons the attempt without either message.
- (void)playURL:(NSString *)urlString;
/// YES between -playURL: and the stream being open (or failing).
- (BOOL)isConnecting;
/// Start playback, or resume after -pause.
- (void)play;
- (void)pause;
/// Moves the position; works while playing, paused, or before -play.
- (void)seekToTime:(NSTimeInterval)seconds;
/// Gain applied on top of the volume, for fading in and out; 1 by default.
- (float)fadeGain;
- (void)setFadeGain:(float)gain;
/// Moves the fade gain smoothly to the target over the duration.
- (void)fadeToGain:(float)gain duration:(NSTimeInterval)duration;
/// Stop playback and wait for the playback thread to end.
- (void)stop;
/// Stop and release all resources of the stream.
- (void)close;

@end

#endif /* StreamPlayer_h */
