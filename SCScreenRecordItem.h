//
//  SCScreenRecordItem.h
//  Pods
//
//  Created by Jonathan on 2019/6/21.
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCScreenRecordItem : NSObject
//要录制的视图是哪个 view或者webview选一个
@property (nonatomic, strong, nullable) UIView *view;
@property (nonatomic, strong, nullable) WKWebView *webView;
///webview是否是webGL模式 不是webGL模式不需要特殊处理
@property (nonatomic, assign) BOOL isWebViewUsingWebGL;
///图像合成在什么位置上
@property (nonatomic, assign) CGRect frame;
@end

NS_ASSUME_NONNULL_END
