//
//  ChangeSkinService.m
//  ChangeSkin
//
//  Created by Agenric on 2016/12/12.
//  Copyright © 2016年 Agenric. All rights reserved.
//

#import "ChangeSkinService.h"
#import <AFNetworking/AFNetworking.h>
#import <SSZipArchive/SSZipArchive.h>
#import "UIImage+ChangeSkin.h"

#define ChangeSkinUrl           @"http://10.75.83.3/api/index/changeSkin"

static NSString * const CS_StartTimeKey = @"ChangeSkinStartTimeKey";
static NSString * const CS_EndTimeKey = @"ChangeSkinEndTimeKey";
static NSString * const CS_VersionKey = @"ChangeSkinVersionKey";
static NSString * const CS_ResourceStatusKey = @"ChangeSkinResourceStatusKey";

typedef NS_ENUM(NSInteger, ResourceStatus) {
    ResourceStatus_UnKnow = -1,
    ResourceStatus_UnDownload = 0,
    ResourceStatus_Downloading = 1,
    ResourceStatus_Downloaded = 2
};

static inline NSURL * DocumentsDirectoryURL() {
    return [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
}

static inline NSString * ResourceFile() {
    return [[DocumentsDirectoryURL() path] stringByAppendingPathComponent:@"/SkinFile"];
}

@interface ChangeSkinService ()

// 开始时间
@property (nonatomic, copy) NSString *startTime;
// 结束时间
@property (nonatomic, copy) NSString *endTime;
// 资源版本号，递增
@property (nonatomic, copy) NSString *version;
// 资源包状态 - 未知 未下载 下载中 已下载
@property (nonatomic, assign) ResourceStatus resourceStatus;

@property (nonatomic, assign, readwrite) BOOL shouldChangeSkin;

@end

@implementation ChangeSkinService
#pragma mark - Life Cycle
+ (id)sharedInstance {
    static id instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self configMetadata];
    }
    return self;
}

- (void)configMetadata {
    self.startTime = [[NSUserDefaults standardUserDefaults] stringForKey:CS_StartTimeKey] ? [[NSUserDefaults standardUserDefaults] stringForKey:CS_StartTimeKey] : @"1970-01-01 00:00:00";
    self.endTime = [[NSUserDefaults standardUserDefaults] stringForKey:CS_EndTimeKey] ? [[NSUserDefaults standardUserDefaults] stringForKey:CS_EndTimeKey] : @"1970-01-01 00:00:01";
    self.version = [[NSUserDefaults standardUserDefaults] stringForKey:CS_VersionKey] ? [[NSUserDefaults standardUserDefaults] stringForKey:CS_VersionKey] : @"0";
    self.resourceStatus = [[NSUserDefaults standardUserDefaults] integerForKey:CS_ResourceStatusKey] ? [[NSUserDefaults standardUserDefaults] integerForKey:CS_ResourceStatusKey]: ResourceStatus_UnKnow;
    
    if (self.resourceStatus == ResourceStatus_Downloaded && [self isInRangeOfStartTime:self.startTime endTime:self.endTime]) {
        self.shouldChangeSkin = YES;
    } else {
        self.shouldChangeSkin = NO;
    }
}

- (NSString *)resourceFile {
    return ResourceFile();
}

#pragma mark - Private Methods
- (void)configService {
    // 请求换肤接口
    __weak typeof(self) weakSelf = self;
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager POST:ChangeSkinUrl parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if ([responseObject isKindOfClass:[NSDictionary class]]) {
            NSString *newVersion = [responseObject valueForKey:@"version"];
            if ([newVersion compare:strongSelf.version options:NSNumericSearch] == NSOrderedDescending) {
                // 已经有新的资源包了 删除之前的图片资源
                NSFileManager *fileManager = [NSFileManager defaultManager];
                [fileManager removeItemAtPath:ResourceFile() error:nil];
                
                NSDate *endTime = [strongSelf getDateWithString:[responseObject valueForKey:@"endTime"]];
                NSDate *nowTime = [NSDate date];
                if ([nowTime compare:endTime] == NSOrderedAscending) {
                    self.resourceStatus = ResourceStatus_UnDownload;
                    self.startTime = [responseObject valueForKey:@"startTime"];
                    self.endTime = [responseObject valueForKey:@"endTime"];
                    self.version = newVersion;
                    
                    [strongSelf downloadResourceWith:[responseObject valueForKey:@"resourceUrl"]];
                } else {
                    // 该次活动期间用户都没有打开，但活动已经结束，也不用下载资源包
                }
            } else if ([newVersion compare:strongSelf.version options:NSNumericSearch] == NSOrderedAscending) {
                
            } else {
                if (self.resourceStatus != ResourceStatus_Downloaded) { // 版本号一致，但是资源没有下载到本地
                    NSDate *endTime = [strongSelf getDateWithString:[responseObject valueForKey:@"endTime"]];
                    NSDate *nowTime = [NSDate date];
                    if ([nowTime compare:endTime] == NSOrderedAscending) {
                        self.resourceStatus = ResourceStatus_UnDownload;
                        self.startTime = [responseObject valueForKey:@"startTime"];
                        self.endTime = [responseObject valueForKey:@"endTime"];
                        self.version = newVersion;
                        
                        [strongSelf downloadResourceWith:[responseObject valueForKey:@"resourceUrl"]];
                    } else {
                        // 该次活动期间用户都没有打开，但活动已经结束，也不用下载资源包
                    }
                }
            }
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        
    }];
    
}

- (void)downloadResourceWith:(NSString *)resourceUrl {
    NSLog(@"开始下载资源包");
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    NSURL *URL = [NSURL URLWithString:resourceUrl];
    NSURLRequest *request = [NSURLRequest requestWithURL:URL];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        self.resourceStatus = ResourceStatus_Downloading;
        return [DocumentsDirectoryURL() URLByAppendingPathComponent:[response suggestedFilename]];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        NSLog(@"资源包已下载到：%@", filePath);
        NSLog(@"开始解压资源包");
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [SSZipArchive unzipFileAtPath:[filePath path] toDestination:ResourceFile() overwrite:YES password:@"password" progressHandler:^(NSString * _Nonnull entry, unz_file_info zipInfo, long entryNumber, long total) {
            
        } completionHandler:^(NSString * _Nonnull path, BOOL succeeded, NSError * _Nonnull error) {
            if (succeeded) {
                NSFileManager *fileManager = [NSFileManager defaultManager];
                [fileManager removeItemAtPath:[filePath path] error:nil];
                [strongSelf handleData];
            }
        }];
    }];
    [downloadTask resume];
}

// 最新资源包已经下载完成，处理后续操作
- (void)handleData {
    self.resourceStatus = ResourceStatus_Downloaded;
    // 设置资源状态为已下载完成
    [[NSUserDefaults standardUserDefaults] setInteger:self.resourceStatus forKey:CS_ResourceStatusKey];
    // 设置本地版本
    [[NSUserDefaults standardUserDefaults] setObject:self.version forKey:CS_VersionKey];
    // 设置本地起始时间
    [[NSUserDefaults standardUserDefaults] setObject:self.startTime forKey:CS_StartTimeKey];
    [[NSUserDefaults standardUserDefaults] setObject:self.endTime forKey:CS_EndTimeKey];
    
    [[NSUserDefaults standardUserDefaults] synchronize];
//    if (self.resourceStatus == ResourceStatus_Downloaded && [self isInRangeOfStartTime:self.startTime endTime:self.endTime]) {
//        self.shouldChangeSkin = YES;
//    } else {
//        self.shouldChangeSkin = NO;
//    }
}

- (NSDate *)getDateWithString:(NSString *)dateString {
    NSDateFormatter * formatter = [[NSDateFormatter alloc]init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSDate *date = [formatter dateFromString:dateString];
    return date;
}

- (BOOL)isInRangeOfStartTime:(NSString *)startTime endTime:(NSString*)endTime {
    NSDateFormatter * formatter = [[NSDateFormatter alloc]init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSDate *startDate = [formatter dateFromString:startTime];
    NSDate *endDate = [formatter dateFromString:endTime];
    NSDate *nowDate = [NSDate date];
    
    if ([nowDate compare:startDate] == NSOrderedDescending && [nowDate compare:endDate] == NSOrderedAscending) {
        return YES;
    }
    return NO;
}

@end

