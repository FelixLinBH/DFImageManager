// The MIT License (MIT)
//
// Copyright (c) 2015 Alexander Grebenyuk (github.com/kean).
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "DFImageRequest.h"
#import "DFImageRequestOptions.h"
#import "DFURLHTTPResponseValidator.h"
#import "DFURLImageFetcher.h"
#import "DFURLResponseValidating.h"

NSString *const DFURLRequestCachePolicyKey = @"DFURLRequestCachePolicyKey";


@interface _DFURLSessionOperation : NSOperation

@property (nonatomic, copy) void (^cancellationHandler)(void);
@property (nonatomic, copy) void (^priorityHandler)(NSOperationQueuePriority priority);

@end

@implementation _DFURLSessionOperation

- (void)cancel {
    @synchronized(self) {
        if (!self.isCancelled) {
            [super cancel];
            if (self.cancellationHandler) {
                self.cancellationHandler();
            }
        }
    }
}

- (void)setQueuePriority:(NSOperationQueuePriority)queuePriority {
    super.queuePriority = queuePriority;
    if (self.priorityHandler) {
        self.priorityHandler(queuePriority);
    }
}

@end


typedef void (^_DFURLSessionDataTaskProgressHandler)(NSData *data, int64_t countOfBytesReceived, int64_t countOfBytesExpectedToReceive);
typedef void (^_DFURLSessionDataTaskCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error);

@interface _DFURLSessionDataTaskHandler : NSObject

@property (nonatomic, copy, readonly) _DFURLSessionDataTaskProgressHandler progressHandler;
@property (nonatomic, copy, readonly) _DFURLSessionDataTaskCompletionHandler completionHandler;
@property (nonatomic, readonly) NSMutableData *data;

- (instancetype)initWithProgressHandler:(_DFURLSessionDataTaskProgressHandler)progressHandler completion:(_DFURLSessionDataTaskCompletionHandler)completion;

@end

@implementation _DFURLSessionDataTaskHandler

- (instancetype)initWithProgressHandler:(_DFURLSessionDataTaskProgressHandler)progressHandler completion:(_DFURLSessionDataTaskCompletionHandler)completionHandler {
    if (self = [super init]) {
        _progressHandler = [progressHandler copy];
        _completionHandler = [completionHandler copy];
        _data = [NSMutableData new];
    }
    return self;
}

@end


static const NSTimeInterval _kTaskExecutionInterval = 0.005; // 5 ms

/*! The _DFURLFetcherTaskQueue serves multiple puproses:
 - Prevents NSURLSession trashing
 - Prevents excessive resuming of tasks during the extremely fast scrolling
 - Limits the possibility of the known system crash http://prod.lists.apple.com/archives/macnetworkprog/2014/Oct/msg00001.html that sometimes reproduces on an older devices. It does NOT reproduce on newer devices.
 */
@interface _DFURLFetcherTaskQueue : NSObject
@end

@implementation _DFURLFetcherTaskQueue {
    NSMutableOrderedSet *_pendingTasks;
    BOOL _executing;
}

- (instancetype)init {
    if (self = [super init]) {
        _pendingTasks = [NSMutableOrderedSet new];
    }
    return self;
}

- (void)resumeTask:(NSURLSessionTask *)task {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_pendingTasks addObject:task];
        [self _setNeedsResumePendingTasks];
    });
}

- (void)cancelTask:(NSURLSessionTask *)task {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_pendingTasks containsObject:task]) {
            [_pendingTasks removeObject:task];
        } else {
            [task cancel];
        }
    });
}

/*! Gurantees that there is is at least '_kTaskExecutionInterval' seconds between the execution of each task.
 */
- (void)_setNeedsResumePendingTasks {
    if (!_executing) {
        _executing = YES;
        typeof(self) __weak weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_kTaskExecutionInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf _resumePendingTask];
        });
    }
}

- (void)_resumePendingTask {
    _executing = NO;
    NSURLSessionTask *task = _pendingTasks.firstObject;
    if (task) {
        [task resume];
        [_pendingTasks removeObject:task];
    }
    if (_pendingTasks.count) {
        [self _setNeedsResumePendingTasks];
    }
}

@end


@implementation DFURLImageFetcher {
    NSMutableDictionary *_sessionTaskHandlers;
    _DFURLFetcherTaskQueue *_taskQueue;
}

DF_INIT_UNAVAILABLE_IMPL

- (instancetype)initWithSession:(NSURLSession *)session sessionDelegate:(id<DFURLImageFetcherSessionDelegate>)sessionDelegate {
    NSParameterAssert(session);
    NSParameterAssert(sessionDelegate);
    if (self = [super init]) {
        _session = session;
        _sessionDelegate = sessionDelegate;
        _sessionTaskHandlers = [NSMutableDictionary new];
        _taskQueue = [_DFURLFetcherTaskQueue new];
        _supportedSchemes = [NSSet setWithObjects:@"http", @"https", @"ftp", @"file", @"data", nil];
    }
    return self;
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    NSParameterAssert(configuration);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    return [self initWithSession:session sessionDelegate:self];
}

#pragma mark <DFImageFetching>

- (BOOL)canHandleRequest:(nonnull DFImageRequest *)request {
    if ([request.resource isKindOfClass:[NSURL class]]) {
        return [self.supportedSchemes containsObject:((NSURL *)request.resource).scheme];
    }
    return NO;
}

- (BOOL)isRequestFetchEquivalent:(DFImageRequest *)request1 toRequest:(DFImageRequest *)request2 {
    if (![self isRequestCacheEquivalent:request1 toRequest:request2]) {
        return NO;
    }
    NSURLRequestCachePolicy defaultCachePolicy = self.session.configuration.requestCachePolicy;
    NSURLRequestCachePolicy requestCachePolicy1 = request1.options.userInfo[DFURLRequestCachePolicyKey] ? [request1.options.userInfo[DFURLRequestCachePolicyKey] unsignedIntegerValue] : defaultCachePolicy;
    NSURLRequestCachePolicy requestCachePolicy2 = request2.options.userInfo[DFURLRequestCachePolicyKey] ? [request2.options.userInfo[DFURLRequestCachePolicyKey] unsignedIntegerValue] : defaultCachePolicy;
    return requestCachePolicy1 == requestCachePolicy2;
}

- (BOOL)isRequestCacheEquivalent:(DFImageRequest *)request1 toRequest:(DFImageRequest *)request2 {
    return request1 == request2 || [(NSURL *)request1.resource isEqual:(NSURL *)request2.resource];
}

- (nonnull NSOperation *)startOperationWithRequest:(nonnull DFImageRequest *)request progressHandler:(nullable DFImageFetchingProgressHandler)progressHandler completion:(nullable DFImageFetchingCompletionHandler)completion {
    typeof(self) __weak weakSelf = self;
    NSURLRequest *URLRequest = [self _URLRequestForImageRequest:request];
    NSURLSessionDataTask *__block task = [self.sessionDelegate URLImageFetcher:self dataTaskWithRequest:URLRequest progressHandler:^(NSData *data, int64_t countOfBytesReceived, int64_t countOfBytesExpectedToReceive) {
        if (progressHandler) {
            progressHandler(data, countOfBytesReceived, countOfBytesExpectedToReceive);
        }
    } completionHandler:^(NSData *data, NSURLResponse *URLResponse, NSError *error) {
        NSData *receivedData = data;
        if (receivedData) {
            id<DFURLResponseValidating> validator = [weakSelf _responseValidatorForImageRequest:request URLRequest:URLRequest];
            if (validator && ![validator isValidResponse:URLResponse data:data error:&error]) {
                receivedData = nil;
            }
        }
        if (completion) {
            completion(receivedData, nil, error);
        }
    }];
    
    // Passive container, DFURLImageFetcher never even start the operation, it only uses it's -cancel and -setPririty APIs. DFImageManager should probably have a specific protocol instead of NSOperation, because sometimes there is not need in one.
    _DFURLSessionOperation *operation = [_DFURLSessionOperation new];
    operation.cancellationHandler = ^{
        [_taskQueue cancelTask:task];
    };
    operation.priorityHandler = ^(NSOperationQueuePriority priority) {
        if ([task respondsToSelector:@selector(setPriority:)]) {
            task.priority = [DFURLImageFetcher _taskPriorityForQueuePriority:priority];
        }
    };
    
    [_taskQueue resumeTask:task];
    
    return operation;
}

+ (float)_taskPriorityForQueuePriority:(NSOperationQueuePriority)queuePriority {
    switch (queuePriority) {
        case NSOperationQueuePriorityVeryHigh: return 0.9f;
        case NSOperationQueuePriorityHigh: return 0.7f;
        case NSOperationQueuePriorityNormal: return 0.5f;
        case NSOperationQueuePriorityLow: return 0.3f;
        case NSOperationQueuePriorityVeryLow: return 0.1f;
    }
}

- (NSURLRequest *)_URLRequestForImageRequest:(DFImageRequest *)imageRequest {
    NSURLRequest *URLRequest = [self _defaultURLRequestForImageRequest:imageRequest];
    if ([self.delegate respondsToSelector:@selector(URLImageFetcher:URLRequestForImageRequest:URLRequest:)]) {
        URLRequest = [self.delegate URLImageFetcher:self URLRequestForImageRequest:imageRequest URLRequest:URLRequest];
    }
    return URLRequest;
}

- (NSURLRequest *)_defaultURLRequestForImageRequest:(DFImageRequest *)imageRequest {
    NSMutableURLRequest *URLRequest = [[NSMutableURLRequest alloc] initWithURL:(NSURL *)imageRequest.resource];
#ifdef DF_IMAGE_MANAGER_WEBP_AVAILABLE
    [URLRequest addValue:@"image/webp,image/*;q=0.8" forHTTPHeaderField:@"Accept"];
#else
    [URLRequest addValue:@"image/*" forHTTPHeaderField:@"Accept"];
#endif
    DFImageRequestOptions *options = imageRequest.options;
    if (options.userInfo[DFURLRequestCachePolicyKey]) {
        URLRequest.cachePolicy = [options.userInfo[DFURLRequestCachePolicyKey] unsignedIntegerValue];
    } else {
        URLRequest.cachePolicy = options.allowsNetworkAccess ? self.session.configuration.requestCachePolicy : NSURLRequestReturnCacheDataDontLoad;
    }
    return [URLRequest copy];
}

- (nullable id<DFURLResponseValidating>)_responseValidatorForImageRequest:(nonnull DFImageRequest *)imageRequest URLRequest:(nonnull NSURLRequest *)URLRequest {
    if ([self.delegate respondsToSelector:@selector(URLImageFetcher:responseValidatorForImageRequest:URLRequest:)]) {
        return [self.delegate URLImageFetcher:self responseValidatorForImageRequest:imageRequest URLRequest:URLRequest];
    }
    if ([URLRequest.URL.scheme hasPrefix:@"http"]) {
        return [DFURLHTTPResponseValidator new];
    } else {
        return nil;
    }
}

- (void)removeAllCachedImages {
    [_session.configuration.URLCache removeAllCachedResponses];
}

#pragma mark <NSURLSessionDataTaskDelegate>

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    @synchronized(self) {
        _DFURLSessionDataTaskHandler *handler = _sessionTaskHandlers[dataTask];
        if (handler.progressHandler) {
            handler.progressHandler(data, dataTask.countOfBytesReceived, dataTask.countOfBytesExpectedToReceive);
        }
        [handler.data appendData:data];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized(self) {
        _DFURLSessionDataTaskHandler *handler = _sessionTaskHandlers[task];
        if (handler.completionHandler) {
            handler.completionHandler(handler.data, task.response, error);
        }
        [_sessionTaskHandlers removeObjectForKey:task];
    }
    if (error && [self.delegate respondsToSelector:@selector(URLImageFetcher:didEncounterError:)]) {
        [self.delegate URLImageFetcher:self didEncounterError:error];
    }
}

#pragma mark <DFURLImageFetcherSessionDelegate>

- (NSURLSessionDataTask *)URLImageFetcher:(DFURLImageFetcher *)fetcher dataTaskWithRequest:(NSURLRequest *)request progressHandler:(_DFURLSessionDataTaskProgressHandler)progressHandler completionHandler:(_DFURLSessionDataTaskCompletionHandler)completionHandler {
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    if (task) {
        @synchronized(self) {
            _sessionTaskHandlers[task] = [[_DFURLSessionDataTaskHandler alloc] initWithProgressHandler:progressHandler completion:completionHandler];
        }
    }
    return task;
}

@end
