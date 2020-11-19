/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "UIView+WebCacheOperation.h"
#import "objc/runtime.h"

static char loadOperationKey;

// key is strong, value is weak because operation instance is retained by SDWebImageManager's runningOperations property
// we should use lock to keep thread-safe because these method may not be accessed from main queue
typedef NSMapTable<NSString *, id<SDWebImageOperation>> SDOperationsDictionary;

@implementation UIView (WebCacheOperation)

- (SDOperationsDictionary *)sd_operationDictionary {
    // 加锁, 保证线程安全
    @synchronized(self) {
        // 通过关联对象,获取map字典
        SDOperationsDictionary *operations = objc_getAssociatedObject(self, &loadOperationKey);
        // 如果存在,就返回
        if (operations) {
            return operations;
        }
        // 如果没有,创建key为强引用、value为弱引用的map字典
        operations = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory capacity:0];
        // 通过关联对象,保存map字典
        objc_setAssociatedObject(self, &loadOperationKey, operations, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 返回新建的map字典
        return operations;
    }
}

- (nullable id<SDWebImageOperation>)sd_imageLoadOperationForKey:(nullable NSString *)key  {
    id<SDWebImageOperation> operation;
    if (key) {
        SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
        @synchronized (self) {
            operation = [operationDictionary objectForKey:key];
        }
    }
    return operation;
}

// 将该控件上的图片加载操作和validOperationKey一一对应保存起来
- (void)sd_setImageLoadOperation:(nullable id<SDWebImageOperation>)operation forKey:(nullable NSString *)key {
    // 必须要传入参数key
    if (key) {
        // 先取消掉key对应的操作
        [self sd_cancelImageLoadOperationWithKey:key];
        // 必须要传入参数operation
        if (operation) {
            // 获取到保存用的字典，并在线程安全的状态下保存
            SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
            @synchronized (self) {
                [operationDictionary setObject:operation forKey:key];
            }
        }
    }
}

// 取消掉该控件上validOperationKey对应的图片加载操作
- (void)sd_cancelImageLoadOperationWithKey:(nullable NSString *)key {
    if (key) {
        // Cancel in progress downloader from queue
        // 获取继承自NSMapTable的自定义字典对象
        SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
        id<SDWebImageOperation> operation;
        
        // 在加锁保护下获取到操作对象
        @synchronized (self) {
            operation = [operationDictionary objectForKey:key];
        }
        // 如果获取到了操作对象就取消，并且从字典中移除
        if (operation) {
            if ([operation conformsToProtocol:@protocol(SDWebImageOperation)]) {
                [operation cancel];
            }
            @synchronized (self) {
                [operationDictionary removeObjectForKey:key];
            }
        }
    }
}

- (void)sd_removeImageLoadOperationWithKey:(nullable NSString *)key {
    if (key) {
        SDOperationsDictionary *operationDictionary = [self sd_operationDictionary];
        @synchronized (self) {
            [operationDictionary removeObjectForKey:key];
        }
    }
}

@end
