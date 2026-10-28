//
//  FFmpegController.h
//  uniplayer//
//  Created by lhc on 9/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface FFThumbnail: NSObject

@property(nonatomic) NSImage * _Nullable image;
@property(nonatomic) double realTime;

@end


@protocol FFmpegControllerDelegate <NSObject>

/**
 A notification being sent
 */
- (void)didUpdateThumbnails:(nullable NSArray<FFThumbnail *> *)thumbnails forFile:(nonnull NSString *)filename withProgress:(NSInteger)progress;

/**
 Did generated thumbnails for the video.
 */
- (void)didGenerateThumbnails:(nonnull NSArray<FFThumbnail *> *)thumbnails forFile:(nonnull NSString *)filename succeeded:(BOOL)succeeded;

@end


@interface FFmpegController: NSObject

@property(nonatomic, weak) id<FFmpegControllerDelegate> _Nullable delegate;

@property(nonatomic) NSInteger thumbnailCount;

/// Initializes and returns an image object with the contents of the specified URL
///
/// At this time, the normal [NSImage](https://developer.apple.com/documentation/appkit/nsimage/1519907-init)
/// initializer will fail to create an image object if the image file was encoded in [JPEG XL](https://jpeg.org/jpegxl/) format.
/// In older versions of macOS this will also occur if the image file was encoded in [WebP](https://en.wikipedia.org/wiki/WebP/)
/// format. As these are supported formats for screenshots it is desirable to have an alternative method for creating image objects that
/// supports these formats so that a screenshot preview can be displayed as is done for other screenshot formats. This method is
/// intended to be used when the normal AppKit supplied initializer is unable to create an image.
/// - Attention: This method only supports decoding JPEG XL and WebP encoded images. It is not intended to replace the normal
///       AppKit supplied initializer.
/// - Parameter url: The URL identifying the image.
/// - Returns: An initialized NSImage object or null if the method cannot create an image representation from the contents of the
///       specified URL.
+ (nullable NSImage *)createNSImageWithContentsOfURL:(nonnull NSURL *)url;

- (void)generateThumbnailForFile:(nonnull NSString *)file
                      thumbWidth:(int)thumbWidth;

/// Read artwork from the file with the given URL.
///
/// This method will open the file and search the streams for one that contains front cover artwork. If found the image data will be read
/// from the stream and an `NSImage` will be constructed and returned.
/// - Parameter url: URL of the file to read artwork from.
/// - Returns: An initialized NSImage object containing the artwork or null if no artwork was found.
+ (nullable NSImage *)readArtworkFromURL:(nonnull NSURL *)url;

/// Read one video frame for a poster.
///
/// Seeks to `seconds` (0 means 10% of the duration, clamped to one second and
/// sixty seconds), decodes the first available frame and returns it scaled to
/// `maxWidth`. This covers containers AVFoundation does not support, such as
/// MKV and M2TS.
+ (nullable NSImage *)readFrameFromURL:(nonnull NSURL *)url
                                    at:(double)seconds
                              maxWidth:(int)maxWidth;

+ (nullable NSDictionary *)probeVideoInfoForFile:(nonnull NSString *)file;

@end

@class AVAudioPCMBuffer;

/// Decodes one audio track from any container libavformat can open.
///
/// This exists because AVFoundation has no Matroska demuxer: an MKV handed to
/// `AVURLAsset` fails to load its tracks at all, which used to leave live
/// translation depending on the system-audio tap. The decoder's output is
/// float32 PCM at the track's own sample rate and channel count, planar, so
/// the caller can feed it to `AVAudioConverter` for the resample and downmix
/// rather than reimplementing them here.
///
/// Single consumer: one instance is read by one thread at a time, and `close`
/// must not race a read.
@interface FFmpegAudioDecoder : NSObject

/// Opens `url` and prepares the audio track at `ordinal` (0 is the first audio
/// track, matching mpv's aid ordering). `languageHint` (an ISO code such as
/// "eng" or "jpn") wins over the ordinal when a track carries it.
+ (nullable instancetype)decoderWithURL:(nonnull NSURL *)url
                           trackOrdinal:(NSInteger)ordinal
                          languageHint:(nullable NSString *)hint
                                 error:(NSError *_Nullable *_Nullable)error;

/// Returns the next decoded chunk, or an empty (zero-frame) buffer at the end
/// of the track. `seconds` is the chunk's presentation time in the track's own
/// timebase. A nil return is always a failure with `error` set: "end of
/// stream" is a buffer with no frames, because a nil return from an
/// error-taking method reads to Swift as an error even when none was set.
- (nullable AVAudioPCMBuffer *)nextBufferWithSeconds:(double *_Nullable)seconds
                                               error:(NSError *_Nullable *_Nullable)error;


/// Seeks to `seconds` and discards decoder state, so the next read starts at
/// or just before that point.
- (BOOL)seekToSeconds:(double)seconds error:(NSError *_Nullable *_Nullable)error;

- (void)close;

@end
