//
//  GRRequestsManager.m
//  GoldRaccoon
//  v1.0.1
//
//  Created by Alberto De Bortoli on 14/06/2013.
//  Copyright 2013 Alberto De Bortoli. All rights reserved.
//

#import "GRRequestsManager.h"

#import "GRListingRequest.h"
#import "GRCreateDirectoryRequest.h"
#import "GRUploadRequest.h"
#import "GRDownloadRequest.h"
#import "GRDeleteRequest.h"

#import "GRQueue.h"

@interface GRRequestsManager () <GRRequestDelegate, GRRequestDataSource>

@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, strong) GRQueue *requestQueue;
@property (nonatomic, strong) GRRequest *currentRequest;

- (id<GRRequestProtocol>)_addRequestOfType:(Class)clazz withPath:(NSString *)filePath;
- (id<GRDataExchangeRequestProtocol>)_addDataExchangeRequestOfType:(Class)clazz withLocalPath:(NSString *)localPath remotePath:(NSString *)remotePath;
- (void)_enqueueRequest:(id<GRRequestProtocol>)request;
- (void)_processNextRequest;

@end

@implementation GRRequestsManager
{
    NSMutableData *_currentDownloadData;
    NSData *_currentUploadData;
    BOOL _isRunning;
    
@private
    BOOL _delegateRespondsToPercentProgress;
}

@synthesize hostname = _hostname;
@synthesize delegate = _delegate;

#pragma mark - Dealloc and Initialization

- (instancetype)init
{
    NSAssert(NO, @"Initializer not allowed. Use designated initializer initWithHostname:username:password:");
    return nil;
}

- (instancetype)initWithHostname:(NSString *)hostname user:(NSString *)username password:(NSString *)password
{
    NSAssert([hostname length], @"hostname must not be nil");
    
    self = [super init];
    if (self) {
        _hostname = hostname;
        _username = username;
        _password = password;
        _requestQueue = [[GRQueue alloc] init];
        _isRunning = NO;
        _delegateRespondsToPercentProgress = NO;
    }
    return self;
}

- (void)dealloc
{
    [self stopAndCancelAllRequests];
}

#pragma mark - Setters

- (void)setDelegate:(id<GRRequestsManagerDelegate>)delegate
{
    if (_delegate != delegate) {
        _delegate = delegate;
        _delegateRespondsToPercentProgress = [_delegate respondsToSelector:@selector(requestsManager:didCompletePercent:forRequest:)];
    }
}

#pragma mark - Public Methods

- (void)startProcessingRequests
{
    if (_isRunning == NO) {
        _isRunning = YES;
        [self _processNextRequest];
    }
}

- (void)stopAndCancelAllRequests
{
    [self.requestQueue clear];
    self.currentRequest.cancelDoesNotCallDelegate = TRUE;
    [self.currentRequest cancelRequest];
    self.currentRequest = nil;
    _isRunning = NO;
}

- (BOOL)cancelRequest:(GRRequest *)request
{
    return [self.requestQueue removeObject:request];
}

#pragma mark - FTP Actions

- (id<GRRequestProtocol>)addRequestForListDirectoryAtPath:(NSString *)path
{
    return [self _addRequestOfType:[GRListingRequest class] withPath:path];
}

- (id<GRRequestProtocol>)addRequestForCreateDirectoryAtPath:(NSString *)path
{
    return [self _addRequestOfType:[GRCreateDirectoryRequest class] withPath:path];
}

- (id<GRRequestProtocol>)addRequestForDeleteFileAtPath:(NSString *)filePath
{
    return [self _addRequestOfType:[GRDeleteRequest class] withPath:filePath];
}

- (id<GRRequestProtocol>)addRequestForDeleteDirectoryAtPath:(NSString *)path
{
    return [self _addRequestOfType:[GRDeleteRequest class] withPath:path];
}

- (id<GRDataExchangeRequestProtocol>)addRequestForDownloadFileAtRemotePath:(NSString *)remotePath toLocalPath:(NSString *)localPath
{
    return [self _addDataExchangeRequestOfType:[GRDownloadRequest class] withLocalPath:localPath remotePath:remotePath];
}

- (id<GRDataExchangeRequestProtocol>)addRequestForUploadFileAtLocalPath:(NSString *)localPath toRemotePath:(NSString *)remotePath
{
    return [self _addDataExchangeRequestOfType:[GRUploadRequest class] withLocalPath:localPath remotePath:remotePath];
}

#pragma mark - GRRequestDelegate required

- (void)requestCompleted:(GRRequest *)request
{
    // listing request
    if ([request isKindOfClass:[GRListingRequest class]]) {
        
        NSMutableArray *listing = [NSMutableArray array];
        for (NSDictionary *file in ((GRListingRequest *)request).filesInfo) {
            
            
            /**
             * 数组中存放字典（文件名和格式（kCFFTPResourceType kCFFTPResourceName））
             */
            NSDictionary * dic = @{
                                   @"name":[file objectForKey:(id)kCFFTPResourceName],
                                   @"type":[file objectForKey:(id)kCFFTPResourceType]
                                   };
//            [listing addObject:[file objectForKey:(id)kCFFTPResourceName]];
            [listing addObject:dic];
        }
        if ([self.delegate respondsToSelector:@selector(requestsManager:didCompleteListingRequest:listing:)]) {
            [self.delegate requestsManager:self
                 didCompleteListingRequest:((GRListingRequest *)request)
                                   listing:listing];
        }
    }
    
    // create directory request
    if ([request isKindOfClass:[GRCreateDirectoryRequest class]]) {
        if ([self.delegate respondsToSelector:@selector(requestsManager:didCompleteCreateDirectoryRequest:)]) {
            [self.delegate requestsManager:self didCompleteCreateDirectoryRequest:(GRUploadRequest *)request];
        }
    }

    // delete request
    if ([request isKindOfClass:[GRDeleteRequest class]]) {
        if ([self.delegate respondsToSelector:@selector(requestsManager:didCompleteDeleteRequest:)]) {
            [self.delegate requestsManager:self didCompleteDeleteRequest:(GRUploadRequest *)request];
        }
    }

    // upload request
    if ([request isKindOfClass:[GRUploadRequest class]]) {
        if ([self.delegate respondsToSelector:@selector(requestsManager:didCompleteUploadRequest:)]) {
            [self.delegate requestsManager:self didCompleteUploadRequest:(GRUploadRequest *)request];
        }
        _currentUploadData = nil;
    }
    
    // download request
    else if ([request isKindOfClass:[GRDownloadRequest class]]) {
        NSError *writeError = nil;
        BOOL writeToFileSucceeded = [_currentDownloadData writeToFile:((GRDownloadRequest *)request).localFilePath
                                                              options:NSDataWritingAtomic
                                                                error:&writeError];
        
        if (writeToFileSucceeded && !writeError) {
            if ([self.delegate respondsToSelector:@selector(requestsManager:didCompleteDownloadRequest:)]) {
                [self.delegate requestsManager:self didCompleteDownloadRequest:(GRDownloadRequest *)request];
            }
        }
        else {
            if ([self.delegate respondsToSelector:@selector(requestsManager:didFailWritingFileAtPath:forRequest:error:)]) {
                [self.delegate requestsManager:self
                      didFailWritingFileAtPath:((GRDownloadRequest *)request).localFilePath
                                    forRequest:(GRDownloadRequest *)request
                                         error:writeError];
            }
        }
        _currentDownloadData = nil;
    }
    
    [self _processNextRequest];
}

- (void)requestFailed:(GRRequest *)request
{
    if ([self.delegate respondsToSelector:@selector(requestsManager:didFailRequest:withError:)]) {
        NSError *error = [NSError errorWithDomain:@"com.github.goldraccoon" code:-1000 userInfo:@{@"message": request.error.message}];
        [self.delegate requestsManager:self didFailRequest:request withError:error];
    }
    
    [self _processNextRequest];
}

#pragma mark - GRRequestDelegate optional

- (void)percentCompleted:(float)percent forRequest:(id<GRRequestProtocol>)request
{
    if (_delegateRespondsToPercentProgress) {
        [self.delegate requestsManager:self didCompletePercent:percent forRequest:request];
    }
}

- (void)dataAvailable:(NSData *)data forRequest:(id<GRDataExchangeRequestProtocol>)request
{
    [_currentDownloadData appendData:data];
}

- (BOOL)shouldOverwriteFile:(NSString *)filePath forRequest:(id<GRDataExchangeRequestProtocol>)request
{
    // called only with GRUploadRequest requests
    return YES;
}

#pragma mark - GRRequestDataSource

- (NSString *)hostnameForRequest:(id<GRRequestProtocol>)request
{
    return self.hostname;
}

- (NSString *)usernameForRequest:(id<GRRequestProtocol>)request
{
    return self.username;
}

- (NSString *)passwordForRequest:(id<GRRequestProtocol>)request
{
    return self.password;
}

- (long)dataSizeForUploadRequest:(id<GRDataExchangeRequestProtocol>)request
{
    return [_currentUploadData length];
}

- (NSData *)dataForUploadRequest:(id<GRDataExchangeRequestProtocol>)request
{
    NSData *temp = _currentUploadData;
    _currentUploadData = nil; // next time will return nil;
    return temp;
}

#pragma mark - Private Methods

- (id<GRRequestProtocol>)_addRequestOfType:(Class)clazz withPath:(NSString *)filePath
{
    id<GRRequestProtocol> request = [[clazz alloc] initWithDelegate:self datasource:self];

//    NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
////    [defaults setObject:@"createDirectory" forKey:@"WWcreateDirectory"];
//    NSString * createC = [defaults objectForKey:@"WWcreateDirectory"];
//    if (createC) {
//        if ([self IsChinese:filePath]) {
//            filePath = [self encodeString:filePath];
//        }
//    }
    
    request.path = filePath;
    
    [self _enqueueRequest:request];
    return request;
//    %u5B89%u5353
}

#pragma mark - 判断字符串中是否有中文
-(BOOL)IsChinese:(NSString *)str {
    for(int i=0; i< [str length];i++){
        int a = [str characterAtIndex:i];
        if( a > 0x4e00 && a < 0x9fff)
        {
            return YES;
        }
        
    }
    return NO;
    
}

- (NSString *)encodeString:(NSString *)string;
{
    NSString *urlEncoded = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
                                                                                                 NULL,
                                                                                                 (__bridge CFStringRef) string,
                                                                                                 NULL,
                                                                                                 (CFStringRef)@"!*'\"();:@&=+$,?%#[]% ",
                                                                                                 kCFStringEncodingUTF8);
    return urlEncoded;
}

- (id<GRDataExchangeRequestProtocol>)_addDataExchangeRequestOfType:(Class)clazz withLocalPath:(NSString *)localPath remotePath:(NSString *)remotePath
{
    id<GRDataExchangeRequestProtocol> request = [[clazz alloc] initWithDelegate:self datasource:self];
    request.path = remotePath;
    request.localFilePath = localPath;
    
    [self _enqueueRequest:request];
    return request;
}

- (void)_enqueueRequest:(id<GRRequestProtocol>)request
{
    [self.requestQueue enqueue:request];
}

- (void)_processNextRequest
{
    self.currentRequest = [self.requestQueue dequeue];
    
    if (self.currentRequest == nil) {
        [self stopAndCancelAllRequests];
        return;
    }
    
    if ([self.currentRequest isKindOfClass:[GRDownloadRequest class]]) {
        _currentDownloadData = [NSMutableData dataWithCapacity:4096];
    }
    if ([self.currentRequest isKindOfClass:[GRUploadRequest class]]) {
        NSString *localFilepath = ((GRUploadRequest *)self.currentRequest).localFilePath;
        _currentUploadData = [NSData dataWithContentsOfFile:localFilepath];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.currentRequest start];
    });
    
    if ([self.delegate respondsToSelector:@selector(requestsManager:didStartRequest:)]) {
        [self.delegate requestsManager:self didStartRequest:self.currentRequest];
    }
}

@end
