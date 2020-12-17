/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDDiskCache.h"
#import "SDImageCacheConfig.h"
#import "SDFileAttributeHelper.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const SDDiskCacheExtendedAttributeName = @"com.hackemist.SDDiskCache";

@interface SDDiskCache ()

@property (nonatomic, copy) NSString *diskCachePath;
@property (nonatomic, strong, nonnull) NSFileManager *fileManager;

@end

@implementation SDDiskCache

- (instancetype)init {
    NSAssert(NO, @"Use `initWithCachePath:` with the disk cache path");
    return nil;
}

#pragma mark - SDcachePathForKeyDiskCache Protocol
// 初始化缓存路径/配置
- (instancetype)initWithCachePath:(NSString *)cachePath config:(nonnull SDImageCacheConfig *)config {
    if (self = [super init]) {
        // 沙盒缓存路径
        _diskCachePath = cachePath;
        _config = config;
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    // 初始化文件管理对象
    if (self.config.fileManager) {
        self.fileManager = self.config.fileManager;
    } else {
        self.fileManager = [NSFileManager new];
    }
}

// 缓存是否包含
- (BOOL)containsDataForKey:(NSString *)key {
    NSParameterAssert(key);
    // 文件缓存路径
    NSString *filePath = [self cachePathForKey:key];
    // 文件是否存在
    BOOL exists = [self.fileManager fileExistsAtPath:filePath];
    
    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    if (!exists) {
        // 移除扩展 判断是否存在
        exists = [self.fileManager fileExistsAtPath:filePath.stringByDeletingPathExtension];
    }
    
    return exists;
}

- (NSData *)dataForKey:(NSString *)key {
    NSParameterAssert(key);
    // 文件缓存路径
    NSString *filePath = [self cachePathForKey:key];
    // 获取文件数据
    NSData *data = [NSData dataWithContentsOfFile:filePath options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }
    
    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    // 移除扩展 获取文件数据
    data = [NSData dataWithContentsOfFile:filePath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }
    
    return nil;
}

// 保存数据到沙盒
- (void)setData:(NSData *)data forKey:(NSString *)key {
    NSParameterAssert(data);
    NSParameterAssert(key);
    if (![self.fileManager fileExistsAtPath:self.diskCachePath]) {
        // 初始化沙盒缓存路径
        [self.fileManager createDirectoryAtPath:self.diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    
    // get cache Path for image key
    // 文件缓存路径
    NSString *cachePathForKey = [self cachePathForKey:key];
    // transform to NSURL
    NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];
    
    // 缓存到沙盒
    [data writeToURL:fileURL options:self.config.diskCacheWritingOptions error:nil];
    
    // disable iCloud backup
    if (self.config.shouldDisableiCloud) {
        // ignore iCloud backup resource value error
        // 禁止iCloud备份
        [fileURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}

// 获取扩展数据
- (NSData *)extendedDataForKey:(NSString *)key {
    NSParameterAssert(key);
    
    // get cache Path for image key
    // 文件缓存路径
    NSString *cachePathForKey = [self cachePathForKey:key];
    
    // 扩展数据
    NSData *extendedData = [SDFileAttributeHelper extendedAttribute:SDDiskCacheExtendedAttributeName atPath:cachePathForKey traverseLink:NO error:nil];
    
    return extendedData;
}

// 保存扩展数据
- (void)setExtendedData:(NSData *)extendedData forKey:(NSString *)key {
    NSParameterAssert(key);
    // get cache Path for image key
    // 文件缓存路径
    NSString *cachePathForKey = [self cachePathForKey:key];
    
    if (!extendedData) {
        // Remove
        // 移除扩展数据
        [SDFileAttributeHelper removeExtendedAttribute:SDDiskCacheExtendedAttributeName atPath:cachePathForKey traverseLink:NO error:nil];
    } else {
        // Override
        // 覆盖扩展数据
        [SDFileAttributeHelper setExtendedAttribute:SDDiskCacheExtendedAttributeName value:extendedData atPath:cachePathForKey traverseLink:NO overwrite:YES error:nil];
    }
}

// 移除缓存数据
- (void)removeDataForKey:(NSString *)key {
    NSParameterAssert(key);
    // 文件缓存路径
    NSString *filePath = [self cachePathForKey:key];
    // 移除缓存数据
    [self.fileManager removeItemAtPath:filePath error:nil];
}

// 移除所有缓存数据
- (void)removeAllData {
    [self.fileManager removeItemAtPath:self.diskCachePath error:nil];
    [self.fileManager createDirectoryAtPath:self.diskCachePath
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:NULL];
}

// 移除过期数据
- (void)removeExpiredData {
    // 沙盒缓存地址
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];
    
    // Compute content date key to be used for tests
    // URL资源key
    NSURLResourceKey cacheContentDateKey = NSURLContentModificationDateKey;
    switch (self.config.diskCacheExpireType) {
        case SDImageCacheConfigExpireTypeAccessDate:
            cacheContentDateKey = NSURLContentAccessDateKey;
            break;
        case SDImageCacheConfigExpireTypeModificationDate:
            // 资源内容最后修改时间key
            cacheContentDateKey = NSURLContentModificationDateKey;
            break;
        case SDImageCacheConfigExpireTypeCreationDate:
            cacheContentDateKey = NSURLCreationDateKey;
            break;
        case SDImageCacheConfigExpireTypeChangeDate:
            cacheContentDateKey = NSURLAttributeModificationDateKey;
            break;
        default:
            break;
    }
    
    // NSURLIsDirectoryKey: 资源是否为路径key
    // NSURLTotalFileAllocatedSizeKey:资源分配空间大小
    NSArray<NSString *> *resourceKeys = @[NSURLIsDirectoryKey, cacheContentDateKey, NSURLTotalFileAllocatedSizeKey];
    
    // This enumerator prefetches useful properties for our cache files.
    // 该枚举器为缓存文件预取有用的属性
    NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtURL:diskCacheURL
                                               includingPropertiesForKeys:resourceKeys
                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                             errorHandler:NULL];
    // 开始过期的时间
    NSDate *expirationDate = (self.config.maxDiskAge < 0) ? nil: [NSDate dateWithTimeIntervalSinceNow:-self.config.maxDiskAge];
    
    // 缓存文件
    NSMutableDictionary<NSURL *, NSDictionary<NSString *, id> *> *cacheFiles = [NSMutableDictionary dictionary];
    // 当前沙盒缓存大小
    NSUInteger currentCacheSize = 0;
    
    // Enumerate all of the files in the cache directory.  This loop has two purposes:
    //
    //  1. Removing files that are older than the expiration date.
    //  2. Storing file attributes for the size-based cleanup pass.
    NSMutableArray<NSURL *> *urlsToDelete = [[NSMutableArray alloc] init];
    for (NSURL *fileURL in fileEnumerator) {
        NSError *error;
        NSDictionary<NSString *, id> *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:&error];
        
        // Skip directories and errors. 跳过文件夹和存在错误
        if (error || !resourceValues || [resourceValues[NSURLIsDirectoryKey] boolValue]) {
            continue;
        }
        
        // Remove files that are older than the expiration date;
        // 数据最后修改时间
        NSDate *modifiedDate = resourceValues[cacheContentDateKey];
        // 开始过期的时间存在，开始过期时间比数据最后的修改时间晚
        if (expirationDate && [[modifiedDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
            // 添加到带删除数组
            [urlsToDelete addObject:fileURL];
            continue;
        }
        
        // Store a reference to this file and account for its total size.
        // 资源分配空间大小
        NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
        // 增加计数
        currentCacheSize += totalAllocatedSize.unsignedIntegerValue;
        // 缓存文件
        cacheFiles[fileURL] = resourceValues;
    }
    
    for (NSURL *fileURL in urlsToDelete) {
        // 删除过期资源
        [self.fileManager removeItemAtURL:fileURL error:nil];
    }
    
    // If our remaining disk cache exceeds a configured maximum size, perform a second
    // size-based cleanup pass.  We delete the oldest files first.
    // 沙盒最大缓存大小
    NSUInteger maxDiskSize = self.config.maxDiskSize;
    if (maxDiskSize > 0 && currentCacheSize > maxDiskSize) {
        // 当前沙盒缓存大小，大于设置的最大缓存值
        // Target half of our maximum cache size for this cleanup pass.
        // 目标沙盒缓存大小
        const NSUInteger desiredCacheSize = maxDiskSize / 2;
        
        // Sort the remaining cache files by their last modification time or last access time (oldest first).
        // 根据最后修改时间对沙盒缓存文件进行排序
        NSArray<NSURL *> *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                                 usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                     return [obj1[cacheContentDateKey] compare:obj2[cacheContentDateKey]];
                                                                 }];
        
        // Delete files until we fall below our desired cache size.
        for (NSURL *fileURL in sortedFiles) {
            // 移除资源
            if ([self.fileManager removeItemAtURL:fileURL error:nil]) {
                // 资源数据
                NSDictionary<NSString *, id> *resourceValues = cacheFiles[fileURL];
                // 资源分配空间大小
                NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                // 修改当前沙盒缓存大小
                currentCacheSize -= totalAllocatedSize.unsignedIntegerValue;
                
                if (currentCacheSize < desiredCacheSize) {
                    // 当达到目标缓存大小，退出
                    break;
                }
            }
        }
    }
}

// 缓存路径
- (nullable NSString *)cachePathForKey:(NSString *)key {
    NSParameterAssert(key);
    return [self cachePathForKey:key inPath:self.diskCachePath];
}

// 沙盒缓存空间大小
- (NSUInteger)totalSize {
    NSUInteger size = 0;
    NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];
    for (NSString *fileName in fileEnumerator) {
        NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
        NSDictionary<NSString *, id> *attrs = [self.fileManager attributesOfItemAtPath:filePath error:nil];
        size += [attrs fileSize];
    }
    return size;
}

// 沙盒缓存数量
- (NSUInteger)totalCount {
    NSUInteger count = 0;
    NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];
    count = fileEnumerator.allObjects.count;
    return count;
}

#pragma mark - Cache paths

- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path {
    // 处理文件名称
    NSString *filename = SDDiskCacheFileNameForKey(key);
    // 拼接路径
    return [path stringByAppendingPathComponent:filename];
}

// 移动缓存路径
- (void)moveCacheDirectoryFromPath:(nonnull NSString *)srcPath toPath:(nonnull NSString *)dstPath {
    NSParameterAssert(srcPath);
    NSParameterAssert(dstPath);
    // Check if old path is equal to new path
    if ([srcPath isEqualToString:dstPath]) {
        return;
    }
    BOOL isDirectory;
    // Check if old path is directory
    // 源路径不存在 或 不是文件夹
    if (![self.fileManager fileExistsAtPath:srcPath isDirectory:&isDirectory] || !isDirectory) {
        return;
    }
    // Check if new path is directory
    // 目标路径不存在 或 不是文件夹
    if (![self.fileManager fileExistsAtPath:dstPath isDirectory:&isDirectory] || !isDirectory) {
        if (!isDirectory) {
            // New path is not directory, remove file
            // 不是路径，移除文件
            [self.fileManager removeItemAtPath:dstPath error:nil];
        }
        // 目标父路径
        NSString *dstParentPath = [dstPath stringByDeletingLastPathComponent];
        // Creates any non-existent parent directories as part of creating the directory in path
        // 不存在
        if (![self.fileManager fileExistsAtPath:dstParentPath]) {
            // 进行创建
            [self.fileManager createDirectoryAtPath:dstParentPath withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        // New directory does not exist, rename directory
        // 移动文件夹
        [self.fileManager moveItemAtPath:srcPath toPath:dstPath error:nil];
    } else {
        // New directory exist, merge the files
        // 目标路径已经存在
        // 源路径枚举信息
        NSDirectoryEnumerator *dirEnumerator = [self.fileManager enumeratorAtPath:srcPath];
        NSString *file;
        while ((file = [dirEnumerator nextObject])) {
            // 遍历移动文件
            [self.fileManager moveItemAtPath:[srcPath stringByAppendingPathComponent:file] toPath:[dstPath stringByAppendingPathComponent:file] error:nil];
        }
        // Remove the old path 移除源文件
        [self.fileManager removeItemAtPath:srcPath error:nil];
    }
}

#pragma mark - Hash

#define SD_MAX_FILE_EXTENSION_LENGTH (NAME_MAX - CC_MD5_DIGEST_LENGTH * 2 - 1)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// 检查文件名称
static inline NSString * _Nonnull SDDiskCacheFileNameForKey(NSString * _Nullable key) {
    const char *str = key.UTF8String;
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSURL *keyURL = [NSURL URLWithString:key];
    NSString *ext = keyURL ? keyURL.pathExtension : key.pathExtension;
    // File system has file name length limit, we need to check if ext is too long, we don't add it to the filename
    // 检查文件名称长度 是否大于 系统对文件名称长度的规定
    if (ext.length > SD_MAX_FILE_EXTENSION_LENGTH) {
        ext = nil;
    }
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], ext.length == 0 ? @"" : [NSString stringWithFormat:@".%@", ext]];
    return filename;
}
#pragma clang diagnostic pop

@end
