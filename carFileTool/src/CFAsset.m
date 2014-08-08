//
//  CFAsset.m
//  carFileTool
//
//  Created by Alexander Zielenski on 8/8/14.
//  Copyright (c) 2014 Alexander Zielenski. All rights reserved.
//

#import "CFAsset.h"
#import "CSIBitmapWrapper.h"
#import "CUIThemeGradient.h"
#import "CUIPSDGradientEvaluator.h"
#import "CUIMutableCommonAssetStorage.h"
#import <Opee/Opee.h>
#import <objc/runtime.h>

#define kSLICES 1001
#define kMETRICS 1003
#define kFLAGS 1004
#define kUTI 1005
#define kEXIF 1006

struct _csibitmap {
    unsigned int _field1;
    union {
        unsigned int _field1;
        struct _csibitmapflags {
            unsigned int :1;
            unsigned int :1;
            unsigned int :30;
        } _field2;
    } _field2;
    unsigned int _field3;
    unsigned int _field4;
    unsigned char _field5[0];
};

struct _slice {
    unsigned int x;
    unsigned int y;
    unsigned int width;
    unsigned int height;
};


@interface AZThemePixelRendition : NSObject
@end
@implementation AZThemePixelRendition

- (struct CGImage *)newImageFromCSIDataSlice:(struct _slice)arg1 ofBitmap:(struct _csibitmap *)arg2 usingColorspace:(struct CGColorSpace *)arg3 {
    NSMutableArray *sliceRects = objc_getAssociatedObject(self, "sliceRects");
    if (!sliceRects) {
        sliceRects = [NSMutableArray array];
        objc_setAssociatedObject(self, "sliceRects", sliceRects, OBJC_ASSOCIATION_RETAIN);
    } else
        [sliceRects addObject:[NSValue valueWithRect:NSMakeRect(arg1.x, arg1.y, arg1.width, arg1.height)]];
    return ZKOrig(CGImageRef, arg1, arg2, arg3);
}

@end

static CGRect *originalSlicesFromRendition(CUIThemeRendition *rendition, unsigned int *amount) {
    NSArray *sliceRects = objc_getAssociatedObject(rendition, "sliceRects");
    unsigned int nimages = (unsigned int)sliceRects.count;
    *amount = nimages;
    CGRect *slices = malloc(sizeof(CGRect) * nimages);
    
    for (unsigned int x = 0; x < sliceRects.count; x++) {
        slices[x] = [sliceRects[x] rectValue];
    }
    
    *amount = nimages;
    return slices;
}

/* CSI Format
 csi_header (in CUIThemeRendition.h)
 
 list of metadata in this format:
 
 0xE903 - 1001: Slice rects, First 4 bytes length, next num slices rects, next a list of the slice rects
 0xEB03 - 1003: Metrics – First 4 length, next 4 num metrics, next a list of metrics (struct of 3 CGSizes)
 0xEC03 - 1004: Composition - First 4 lenght, second is the blendmode, third is a float for opacity
 0xED03 - 1005: UTI Type, First 4 length, next 4 length of string, then the string
 0xEE03 - 1006: Image Metadata: First 4 length, next 4 EXIF orientation, (UTI type...?)
 
 unk
 
 GRADIENTS marked DARG with colors as RLOC, and opacity a TCPO format unknown
 0x4D4C4543 - MLEC: Start Image Data?
 */

static CUIPSDGradient *psdGradientFromThemeGradient(CUIThemeGradient *themeGradient, double angle, unsigned int style) {
    Ivar ivar = class_getInstanceVariable([themeGradient class], "gradientEvaluator");
    CUIPSDGradientEvaluator *evaluator = object_getIvar(themeGradient, ivar);
    return [[CUIPSDGradient alloc] initWithEvaluator:evaluator drawingAngle:angle gradientStyle:style];
}

static CUIPSDGradient *psdGradientFromRendition(CUIThemeRendition *rendition) {
    return psdGradientFromThemeGradient(rendition.gradient, rendition.gradientDrawingAngle, rendition.gradientStyle);
}


@interface CFAsset ()
@property (readwrite, strong) CUIThemeRendition *rendition;
@property (readwrite, assign) CGRect *slices;
@property (readwrite, assign) NSUInteger nslices;
@property (readwrite, assign) CUIMetrics *metrics;
@property (readwrite, assign) NSUInteger nmetrics;
@property (strong) CUIRenditionKey *key;
- (void)_initializeSlicesFromCSIData:(NSData *)csiData;
- (void)_initializeMetricsFromCSIData:(NSData *)csiData;
@end

@implementation CFAsset

+ (void)initialize {
    ZKSwizzle(AZThemePixelRendition, _CUIThemePixelRendition);
}

+ (instancetype)assetWithRenditionCSIData:(NSData *)csiData forKey:(struct _renditionkeytoken *)key {
    return [[self alloc] initWithRenditionCSIData:csiData forKey:key];
}

- (instancetype)initWithRenditionCSIData:(NSData *)csiData forKey:(struct _renditionkeytoken *)key {
    if ((self = [self init])) {
        [csiData writeToFile:@"/Users/Alex/Desktop/data" atomically:NO];
        
        self.key = [CUIRenditionKey renditionKeyWithKeyList:key];
        self.rendition = [[objc_getClass("CUIThemeRendition") alloc] initWithCSIData:csiData forKey:key];

        self.gradient = psdGradientFromRendition(self.rendition);
        self.effectPreset = self.rendition.effectPreset;
        if (self.rendition.unslicedImage)
            self.image = [[NSBitmapImageRep alloc] initWithCGImage:self.rendition.unslicedImage];
        [self _initializeSlicesFromCSIData:csiData];
        [self _initializeMetricsFromCSIData:csiData];
    }
    
    return self;
}

- (void)_initializeSlicesFromCSIData:(NSData *)csiData {
    unsigned int bytes = kSLICES;
    NSRange sliceLocation = [csiData rangeOfData:[NSData dataWithBytes:&bytes length:sizeof(bytes)]
                                         options:0
                                           range:NSMakeRange(0, csiData.length)];
    if (sliceLocation.location != NSNotFound) {
        unsigned int nslices = 0;
        [csiData getBytes:&nslices range:NSMakeRange(sliceLocation.location + sizeof(unsigned int) * 2, sizeof(nslices))];
        self.nslices = nslices;
        CGRect *slices = malloc(sizeof(CGRect) * self.nslices);
        for (int idx = 0; idx < nslices; idx++) {
            struct {
                unsigned int x;
                unsigned int y;
                unsigned int w;
                unsigned int h;
            } sliceInts;
            [csiData getBytes:&sliceInts range:NSMakeRange(sliceLocation.location + sizeof(sliceInts) * idx + sizeof(unsigned int) * 3, sizeof(sliceInts))];
            // order may be different
            slices[idx] = NSMakeRect(sliceInts.x, sliceInts.y, sliceInts.w, sliceInts.h);
        }
        
        self.slices = slices;
    }
}

- (void)_initializeMetricsFromCSIData:(NSData *)csiData {
    unsigned int bytes = kMETRICS;
    NSRange metricLocation = [csiData rangeOfData:[NSData dataWithBytes:&bytes length:sizeof(bytes)]
                                          options:0
                                            range:NSMakeRange(0, csiData.length)];
    if (metricLocation.location != NSNotFound) {
        unsigned int nmetrics = 0;
        [csiData getBytes:&nmetrics range:NSMakeRange(metricLocation.location + sizeof(unsigned int) * 2, sizeof(nmetrics))];
        self.nmetrics = nmetrics;

        CUIMetrics *metrics = malloc(sizeof(CUIMetrics) * self.nmetrics);
        for (int idx = 0; idx < nmetrics; idx++) {
            CUIMetrics renditionMetric;

            struct {
                unsigned int a;
                unsigned int b;
                unsigned int c;
                unsigned int d;
                unsigned int e;
                unsigned int f;
            } mtr;
            
            [csiData getBytes:&mtr range:NSMakeRange(metricLocation.location + sizeof(mtr) * idx + sizeof(unsigned int) * 3, sizeof(mtr))];
            renditionMetric.edgeTR = CGSizeMake(mtr.c, mtr.b);
            renditionMetric.edgeBL = CGSizeMake(mtr.a, mtr.d);
            renditionMetric.imageSize = CGSizeMake(mtr.e, mtr.f);
            metrics[idx] = renditionMetric;
        }
        
        self.metrics = metrics;
    }
}

- (void)commitToStorage:(CUIMutableCommonAssetStorage *)assetStorage  :(CUIStructuredThemeStore *)storage {
    if (![self.rendition isKindOfClass:objc_getClass("_CUIThemePixelRendition")] &&
        ![self.rendition isKindOfClass:objc_getClass("_CUIThemeGradientRendition")] &&
        ![self.rendition isKindOfClass:objc_getClass("_CUIThemeEffectRendition")]) {
        // we only save shape effects, gradients, and bitmaps
        return;
    }
    
    CSIGenerator *gen = nil;
    if ([self.rendition isKindOfClass:objc_getClass("_CUIThemeEffectRendition")]) {
        gen = [[CSIGenerator alloc] initWithShapeEffectPreset:self.rendition.effectPreset forScaleFactor:self.rendition.scale];
    } else {
        CGSize size = CGSizeZero;
        if ([self.rendition isKindOfClass:objc_getClass("_CUIThemePixelRendition")]) {
            size = CGSizeMake(CGImageGetWidth(self.image.CGImage), CGImageGetHeight(self.image.CGImage));
        }
        gen = [[CSIGenerator alloc] initWithCanvasSize:size sliceCount:(unsigned int)self.nslices layout:self.rendition.subtype];
    }
    
    if (self.image) {
        CSIBitmapWrapper *wrapper = [[CSIBitmapWrapper alloc] initWithPixelWidth:(unsigned int)self.image.pixelsWide
                                                                     pixelHeight:(unsigned int)self.image.pixelsHigh];
        CGContextDrawImage(wrapper.bitmapContext, CGRectMake(0, 0, self.image.pixelsWide, self.image.pixelsHigh), self.image.CGImage);
        [gen addBitmap:wrapper];
    }
    
    for (unsigned int idx = 0; idx < self.nslices; idx++) {
        [gen addSliceRect:self.slices[idx]];
    }
    
    for (unsigned int idx = 0; idx < self.nmetrics; idx++) {
        [gen addMetrics:self.metrics[idx]];
    }
    
    gen.gradient = self.gradient;
    gen.effectPreset = self.effectPreset;
    
    gen.scaleFactor = self.rendition.scale;
    gen.exifOrientation = self.rendition.exifOrientation;
    gen.opacity = self.rendition.opacity;
    gen.blendMode = self.rendition.blendMode;
    gen.colorSpaceID = self.rendition.colorSpaceID;
    gen.templateRenderingMode = self.rendition.templateRenderingMode;
    gen.isVectorBased = self.rendition.isVectorBased;
    gen.utiType = self.rendition.utiType;
    gen.isRenditionFPO = self.rendition.isHeaderFlaggedFPO;
    gen.name = self.rendition.name;
//    gen.excludedFromContrastFilter = YES;
    
    NSData *renditionKey = [storage _newRenditionKeyDataFromKey:(struct _renditionkeytoken *)self.rendition.key];
    [assetStorage setAsset:[gen CSIRepresentationWithCompression:YES] forKey:renditionKey];
}

@end