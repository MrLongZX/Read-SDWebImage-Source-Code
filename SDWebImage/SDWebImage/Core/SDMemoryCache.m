/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDMemoryCache.h"
#import "SDImageCacheConfig.h"
#import "UIImage+MemoryCacheCost.h"
#import "SDInternalMacros.h"

static void * SDMemoryCacheContext = &SDMemoryCacheContext;

@interface SDMemoryCache <KeyType, ObjectType> ()

// 缓存配置信息
@property (nonatomic, strong, nullable) SDImageCacheConfig *config;
#if SD_UIKIT
// 缓存图片table
@property (nonatomic, strong, nonnull) NSMapTable<KeyType, ObjectType> *weakCache; // strong-weak cache
// 锁,保证数据安全
@property (nonatomic, strong, nonnull) dispatch_semaphore_t weakCacheLock; // a lock to keep the access to `weakCache` thread-safe
#endif
@end

@implementation SDMemoryCache

// 移除观察者、通知、代理
- (void)dealloc {
    [_config removeObserver:self forKeyPath:NSStringFromSelector(@selector(maxMemoryCost)) context:SDMemoryCacheContext];
    [_config removeObserver:self forKeyPath:NSStringFromSelector(@selector(maxMemoryCount)) context:SDMemoryCacheContext];
#if SD_UIKIT
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    self.delegate = nil;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _config = [[SDImageCacheConfig alloc] init];
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithConfig:(SDImageCacheConfig *)config {
    self = [super init];
    if (self) {
        _config = config;
        [self commonInit];
    }
    return self;
}

// 初始化 config, weakCache, weakCacheLock 变量, 添加一个内存警告监听, 内存警告时释放内存.
- (void)commonInit {
    SDImageCacheConfig *config = self.config;
    // 最大内存缓存消耗
    self.totalCostLimit = config.maxMemoryCost;
    // 最大内存缓存数量
    self.countLimit = config.maxMemoryCount;

    // 添加观察者
    [config addObserver:self forKeyPath:NSStringFromSelector(@selector(maxMemoryCost)) options:0 context:SDMemoryCacheContext];
    [config addObserver:self forKeyPath:NSStringFromSelector(@selector(maxMemoryCount)) options:0 context:SDMemoryCacheContext];

#if SD_UIKIT
    // 初始化NSMapTable对象
    self.weakCache = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory capacity:0];
    self.weakCacheLock = dispatch_semaphore_create(1);

    // 内存警告通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveMemoryWarning:)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];
#endif
}

// Current this seems no use on macOS (macOS use virtual memory and do not clear cache when memory warning). So we only override on iOS/tvOS platform.
#if SD_UIKIT
- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    // Only remove cache, but keep weak cache
    // 移除cache缓存，weakCache不移除
    [super removeAllObjects];
}

// `setObject:forKey:` just call this with 0 cost. Override this is enough
// 保存数据 重写父类方法,首先将数据保存内存,然后再将数据存储在 weakCache.(weakCacheLock保证数据安全)
// 如果 shouldUseWeakMemoryCache 为 false 则不存储到 weakCache.
- (void)setObject:(id)obj forKey:(id)key cost:(NSUInteger)g {
    // 缓存到NSCache
    [super setObject:obj forKey:key cost:g];
    if (!self.config.shouldUseWeakMemoryCache) {
        // 配置对象中不允许缓存到weakCache，直接返回
        return;
    }
    if (key && obj) {
        // Store weak cache
        // 加锁
        SD_LOCK(self.weakCacheLock);
        // 缓存到NSMapTable对象中
        [self.weakCache setObject:obj forKey:key];
        // 解锁
        SD_UNLOCK(self.weakCacheLock);
    }
}

// 获取数据 重写父类方法. 判断是否是弱内存缓存,否: 直接返回父类查询对象.是: 在 weakCache 取出相应对象并保存内存中返回.
- (id)objectForKey:(id)key {
    // 从NSCache获取缓存
    id obj = [super objectForKey:key];
    if (!self.config.shouldUseWeakMemoryCache) {
        // 配置对象中不允许缓存到weakCache，直接返回
        return obj;
    }
    if (key && !obj) {
        // Check weak cache
        // 加锁
        SD_LOCK(self.weakCacheLock);
        // 从NSMapTable对象中获取
        obj = [self.weakCache objectForKey:key];
        // 解锁
        SD_UNLOCK(self.weakCacheLock);
        if (obj) {
            // Sync cache
            NSUInteger cost = 0;
            if ([obj isKindOfClass:[UIImage class]]) {
                // 获取内存缓存成本
                cost = [(UIImage *)obj sd_memoryCost];
            }
            // 缓存到NSCache
            [super setObject:obj forKey:key cost:cost];
        }
    }
    return obj;
}

// 根据 key 移除数据 重写父类方法. 如果 shouldUseWeakMemoryCache 为 false 只移除内存数据,为 true 移除 weakCache.
- (void)removeObjectForKey:(id)key {
    // 从NSCache中移除
    [super removeObjectForKey:key];
    if (!self.config.shouldUseWeakMemoryCache) {
        // 配置对象中不允许缓存到weakCache，直接返回
        return;
    }
    if (key) {
        // Remove weak cache
        // 加锁
        SD_LOCK(self.weakCacheLock);
        // 从NSMapTable对象中移除
        [self.weakCache removeObjectForKey:key];
        // 解锁
        SD_UNLOCK(self.weakCacheLock);
    }
}

// 移除数据 重写父类方法. 如果 shouldUseWeakMemoryCache 为 false 只移除内存数据,为 true 移除 weakCache.
- (void)removeAllObjects {
    // 移除NSCache中所有
    [super removeAllObjects];
    if (!self.config.shouldUseWeakMemoryCache) {
        // 配置对象中不允许缓存到weakCache，直接返回
        return;
    }
    // Manually remove should also remove weak cache
    SD_LOCK(self.weakCacheLock);
    // 移除NSMapTable对象中所有
    [self.weakCache removeAllObjects];
    SD_UNLOCK(self.weakCacheLock);
}
#endif

#pragma mark - KVO
// 通过观察者设置最大内存占有量与最大内存缓存数量
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context == SDMemoryCacheContext) {
        // 判断修改数据
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(maxMemoryCost))]) {
            self.totalCostLimit = self.config.maxMemoryCost;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(maxMemoryCount))]) {
            self.countLimit = self.config.maxMemoryCount;
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end
