//
//  SCScreenRecordConfig.h
//  Pods
//
//  Created by Jonathan on 2019/6/22.
//

#import <Foundation/Foundation.h>
#import "SCScreenRecordItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCScreenRecordConfig : NSObject
///画布尺寸
@property (nonatomic, assign) CGSize contentSize;
///录屏帧数
@property (nonatomic, assign) CGFloat fps;
///视频输出尺寸 (像素) 不大于contentSize
@property (nonatomic, assign) CGSize outputSize;

/**
 需要录屏的视图
 如果没有使用WebGL的WebView直接传入它们的父视图 否则webView需要单独传入
 按照数组的顺序合成画面 第一个在最下一层
 */
@property (nonatomic, strong) NSArray <SCScreenRecordItem *> *viewItems;
///保存路径 fileURLWithPath
@property (nonatomic, strong) NSURL *savePath;

@end

NS_ASSUME_NONNULL_END
