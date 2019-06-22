//
//  SCScreenRecorder.h
//  Pods
//
//  Created by Jonathan on 2019/6/21.
//

#import <Foundation/Foundation.h>
#import "SCScreenRecordConfig.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCScreenRecorder : NSObject
@property (nonatomic, assign, readonly) BOOL recording;
- (instancetype)initWithConfig:(SCScreenRecordConfig *)config;
- (void)startRecord;
- (void)stopRecordComplete:(void(^)(NSURL *savePath))completion;
@end

NS_ASSUME_NONNULL_END
