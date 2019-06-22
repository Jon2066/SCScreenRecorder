//
//  SCScreenRecorder.m
//  Pods
//
//  Created by Jonathan on 2019/6/21.
//

#import "SCScreenRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
//#import <AssetsLibrary/AssetsLibrary.h>


#ifndef sc_dispatch_main_async_safe
#define sc_dispatch_main_async_safe(block)\
if (dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL) == dispatch_queue_get_label(dispatch_get_main_queue())) {\
block();\
} else {\
dispatch_async(dispatch_get_main_queue(), block);\
}

#endif


//规避WKMessageHandler循环引用的问题
@interface SCWebMessageHandler : NSObject<WKScriptMessageHandler>
@property (nonatomic,weak)  id<WKScriptMessageHandler> delegate;
@end

@implementation SCWebMessageHandler
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    if([self.delegate respondsToSelector:@selector(userContentController:didReceiveScriptMessage:)]){
        [self.delegate userContentController:userContentController didReceiveScriptMessage:message];
    }
}
@end

@interface  SCScreenRecordWebModel: NSObject
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) WKUserContentController *controller;
@end


@interface SCScreenRecorder ()<WKScriptMessageHandler>
{
    CGColorSpaceRef _rgbColorSpace;
    CVPixelBufferPoolRef _outputBufferPool;
}
@property (nonatomic, strong) SCScreenRecordConfig *config;
///<WKUserContentController内存地址,image>
@property (nonatomic, strong) NSMutableDictionary *webShotImagesDic;
@property (nonatomic, strong) NSArray *webViewArray;
@property (nonatomic, weak)  NSTimer *recordTimer;
@property (nonatomic, strong) dispatch_queue_t recordQueue;
@property (nonatomic, strong) dispatch_semaphore_t recordSemaphore;

@property (nonatomic, strong) dispatch_queue_t writeQueue;

@property (nonatomic, strong) AVAssetWriter *videoWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *avAdaptor;

@property (nonatomic, assign) NSTimeInterval startTime;

@end

@implementation SCScreenRecorder

- (void)dealloc
{

}

- (instancetype)initWithConfig:(SCScreenRecordConfig *)config
{
    self = [super init];
    if (self) {
        _config = config;
        [self setup];
    }
    return self;
}

- (void)clean
{
    self.avAdaptor = nil;
    self.videoWriterInput = nil;
    self.videoWriter = nil;
    CGColorSpaceRelease(_rgbColorSpace);
    CVPixelBufferPoolRelease(_outputBufferPool);
}

- (void)setup
{
    self.recordSemaphore = dispatch_semaphore_create(1);
    
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    for (SCScreenRecordItem *item in self.config.viewItems) {
        if (item.isWebViewUsingWebGL && item.webView) {
            SCWebMessageHandler *messageHandler = [[SCWebMessageHandler alloc] init];
            messageHandler.delegate = self;
            [item.webView.configuration.userContentController addScriptMessageHandler:messageHandler name:@"ScreenShotHandler"];
            [arr addObject:item.webView];
        }
    }
    self.webViewArray = arr.copy;
}

- (void)startRecord
{
    if (_recording) {
        return;
    }
    _recording = YES;
    [self removeFileWithPath:self.config.savePath.path];
    [self setUpWriter];
    __weak typeof(self) weakSelf = self;
    sc_dispatch_main_async_safe(^{
        weakSelf.recordTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/self.config.fps repeats:YES
                                                                 block:^(NSTimer * _Nonnull timer) {
                                                                     [weakSelf screenRecordProcess];
                                                                 }];
    });
}

- (void)stopRecordComplete:(void(^)(NSURL *savePath))completion
{
    if (self.recordTimer) {
        [self.recordTimer invalidate];
        self.recordTimer = nil;
    }
    _recording = NO;
    if (self.videoWriter.status == AVAssetWriterStatusWriting) {
        [self.videoWriterInput markAsFinished];
        __weak typeof(self) weakSelf = self;
        [self.videoWriter finishWritingWithCompletionHandler:^{
            [weakSelf clean];
            if (completion) {
                completion(weakSelf.config.savePath);
            }
        }];
    }
}


- (void)screenRecordProcess
{
    if (self.webViewArray.count) {
        for (WKWebView *webView in self.webViewArray) {
            [self sendScreenShotCommandToWebView:webView];
        }
    }
    else{
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.recordQueue, ^{
            dispatch_semaphore_wait(weakSelf.recordSemaphore, DISPATCH_TIME_FOREVER);
            [weakSelf writeBitMapFrame];
        });
    }
}

- (void)sendScreenShotCommandToWebView:(WKWebView *)webView
{
    NSString * js = @"cc.director.on(cc.Director.EVENT_AFTER_DRAW,() => {\
    var canvas = document.getElementById(\"GameCanvas\");\
    var gl = canvas.getContext('experimental-webgl',{preserveDrawingBuffer: true});\
    var img = gl.canvas.toDataURL('image/png',0.1);\
    cc.director.off(cc.Director.EVENT_AFTER_DRAW);\
    var messagebody = {\"img\":img};\
    var message = {'message': 'screenShotAction','body': messagebody};\
    window.webkit.messageHandlers.ScreenShotHandler.postMessage(JSON.stringify(message));\
    });";
    sc_dispatch_main_async_safe(^{
        [webView evaluateJavaScript:js completionHandler:^(id _Nullable rest, NSError * _Nullable error) {
            //NSLog(@"screenshot error%@", error);
        }];
    });
}

- (void)writeBitMapFrame
{
    if (![self.videoWriterInput isReadyForMoreMediaData]){
        dispatch_semaphore_signal(self.recordSemaphore);
        return;
    }
    
    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, _outputBufferPool, &pixelBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                          CVPixelBufferGetWidth(pixelBuffer),
                                          CVPixelBufferGetHeight(pixelBuffer),
                                          8, CVPixelBufferGetBytesPerRow(pixelBuffer), _rgbColorSpace,
                                          kCGImageAlphaPremultipliedFirst
                                          );
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, self.config.contentSize.height);
    CGContextConcatCTM(context, flipVertical);
    
    //回到主线程 同步操作
    //将每个视图按顺序绘制上去
    dispatch_sync(dispatch_get_main_queue(), ^{
         UIGraphicsPushContext(context);
//        UIGraphicsBeginImageContextWithOptions(self.config.contentSize, YES, 0);
        for (SCScreenRecordItem *item in self.config.viewItems) {
            if (item.isWebViewUsingWebGL) {
                WKUserContentController *controller = item.webView.configuration.userContentController;
                NSString *p = [NSString stringWithFormat:@"%p", controller];
                UIImage *image = self.webShotImagesDic[p];
                if (image) {
                     [image drawInRect:item.frame];
                }
            }
            else{
                if (item.view) {
                    [item.view drawViewHierarchyInRect:item.frame afterScreenUpdates:YES];
                }
                else if (item.webView){
                    [item.webView drawViewHierarchyInRect:item.frame afterScreenUpdates:YES];
                }
            }
        }
//        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
//        UIGraphicsEndImageContext();
        UIGraphicsPopContext();
//        CGContextDrawImage(context, CGRectMake(0, 0, self.config.contentSize.width, self.config.contentSize.height), image.CGImage);
        [self.webShotImagesDic removeAllObjects];
    });
    
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.writeQueue, ^{
        NSTimeInterval interval = CACurrentMediaTime() - weakSelf.startTime;
        CMTime time = CMTimeMake(interval * weakSelf.config.fps, weakSelf.config.fps);
        BOOL success = [weakSelf.avAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
        CVPixelBufferRelease(pixelBuffer);
        if (!success) {
            NSLog(@"Warning: Unable to write buffer to video");
        }
    });
    dispatch_semaphore_signal(self.recordSemaphore);
}

#pragma mark - asset writer -
-(void)setUpWriter
{
    _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(self.config.contentSize.width),
                                       (id)kCVPixelBufferHeightKey : @(self.config.contentSize.height),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(self.config.contentSize.width * 4)
                                       };
    
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
    
    
    NSError* error = nil;
    _videoWriter = [[AVAssetWriter alloc] initWithURL:self.config.savePath
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];
    NSDictionary* outputSettings = @{AVVideoCodecKey: AVVideoCodecH264,
                                    AVVideoWidthKey: [NSNumber numberWithInt:self.config.outputSize.width],
                                    AVVideoHeightKey: [NSNumber numberWithInt:self.config.outputSize.height]};

    _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    
    NSDictionary *sourcePixelBufferAttributes = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB)};

    _avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput sourcePixelBufferAttributes:sourcePixelBufferAttributes];
    
    [_videoWriter addInput:_videoWriterInput];
    
    self.startTime = CACurrentMediaTime();

    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:kCMTimeZero];
}


#pragma mark - file method -

- (void)removeFileWithPath:(NSString*)filePath
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:filePath]) {
        NSError* error;
        if ([fileManager removeItemAtPath:filePath error:&error] == NO) {
//            NSLog(@"Could not delete old recording:%@", [error localizedDescription]);
        }
    }
}

#pragma mark - WKScriptMessageHandler -
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
        if ([message.name isEqualToString:@"ScreenShotHandler"]) {
            NSString* msgBodyString = (NSString*)message.body;
            __weak typeof(self) weakSelf = self;
            dispatch_async(self.recordQueue, ^{
                dispatch_semaphore_wait(weakSelf.recordSemaphore, DISPATCH_TIME_FOREVER);
                NSData *jsonData = [msgBodyString dataUsingEncoding:NSUTF8StringEncoding];
                NSError*err;
                NSDictionary *msgBody = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:&err];
                //NSLog(@"screenShot message =%@", msgBody);
                NSString* msgName = msgBody[@"message"];
                if ([msgName isEqualToString:@"screenShotAction"]) {
                    NSString *dataStr = msgBody[@"body"][@"img"];
                    //实例内存地址
                    NSString *p = [NSString stringWithFormat:@"%p", userContentController];
                    
                    if (dataStr) {
                        dataStr = [dataStr componentsSeparatedByString:@","].lastObject;
                        NSData *data = [[NSData alloc] initWithBase64EncodedString:dataStr options:NSDataBase64DecodingIgnoreUnknownCharacters];
                        UIImage *img = [UIImage imageWithData:data];
                        
                        [weakSelf.webShotImagesDic setObject:img forKey:p];
                        
                    }
                    else{
                        [weakSelf.webShotImagesDic setObject:[[UIImage alloc] init] forKey:p];
                    }
                    //所有web都已经截屏完毕
                    if(weakSelf.webShotImagesDic.count == weakSelf.webViewArray.count){
                        [weakSelf writeBitMapFrame];
                    }
                    else{
                        dispatch_semaphore_signal(weakSelf.recordSemaphore);
                    }
                }
        });

    }
    
}

#pragma mark - lazy load -

- (NSMutableDictionary *)webShotImagesDic
{
    if (!_webShotImagesDic) {
        _webShotImagesDic = [[NSMutableDictionary alloc] init];
    }
    return _webShotImagesDic;
}

- (dispatch_queue_t)recordQueue
{
    if (!_recordQueue) {
        _recordQueue = dispatch_queue_create("sc.screen.record.queue", DISPATCH_QUEUE_SERIAL);
    }
    return _recordQueue;
}

- (dispatch_queue_t)writeQueue
{
    if (!_writeQueue) {
        _writeQueue = dispatch_queue_create("sc.screen.record.write.queue", DISPATCH_QUEUE_SERIAL);
    }
    return _writeQueue;
}

@end
