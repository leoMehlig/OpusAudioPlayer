/*
 * This is the source code of Telegram for iOS v. 1.1
 * It is licensed under GNU GPL v. 2 or later.
 * You should have received a copy of the license in this archive (see LICENSE).
 *
 * Copyright Peter Iakovlev, 2013.
 */

#import <Foundation/Foundation.h>
@protocol OpusAudioPlayerDelegate <NSObject>
- (void) didUpdatePosition: (NSTimeInterval) position;
- (void) didFinishPlaying;
- (void) didStopAtPosition: (NSTimeInterval) position;
- (void) didPauseAtPosition: (NSTimeInterval) postion;
- (void) didStartPlayingFromPosition: (NSTimeInterval) position;
- (void) didFailWithError: (NSError*) error;
@end

@interface OpusAudioPlayer: NSObject

@property (nonatomic, weak) id<OpusAudioPlayerDelegate> delegate;

+ (bool)canPlayFile:(NSString *)path;

- (instancetype)initWithPath:(NSString *)path;

- (void)play;
- (void)playFromPosition:(NSTimeInterval)position;
- (void)pause:(void (^)())completion;
- (void)stop;
- (NSTimeInterval)currentPositionSync:(bool)sync;
- (NSTimeInterval)duration;

@end
