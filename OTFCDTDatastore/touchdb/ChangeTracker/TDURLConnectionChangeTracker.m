//
//  TDURLConnectionChangeTracker.m
//  
//
//  Created by Adam Cox on 1/5/15.
//  Copyright © 2015, 2017 IBM Corp. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//
// <http://wiki.apache.org/couchdb/HTTP_database_API#Changes>
//

#import "TDURLConnectionChangeTracker.h"
#import "TDRemoteRequest.h"
#import "TDAuthorizer.h"
#import "TDStatus.h"
#import "TDBase64.h"
#import "MYURLUtils.h"
#import <string.h>
#import "TDJSON.h"
#import "CDTLogging.h"
#import "TDMisc.h"
#import "CDTURLSession.h"
#import "Test.h"

#define kMaxRetries 6
#define kInitialRetryDelay 0.2

@interface TDURLConnectionChangeTracker()
@property (strong, nonatomic) NSMutableData* inputBuffer;
@property (strong, nonatomic) NSMutableURLRequest *request;
@property (strong, nonatomic) NSDate* startTime;
@property (nonatomic, readwrite) NSUInteger totalRetries;
@property (nonatomic, strong) CDTURLSession * session;
@property (nonatomic, strong) CDTURLSessionTask * task;
@end

static const int kChangeQueueThreshold = 500;
static const float kChangeQueuePollingRate = 0.1f;

@implementation TDURLConnectionChangeTracker

- (instancetype)initWithDatabaseURL:(NSURL *)databaseURL
                               mode:(TDChangeTrackerMode)mode
                          conflicts:(BOOL)includeConflicts
                       lastSequence:(id)lastSequenceID
                             client:(id<TDChangeTrackerClient>)client
                            session:(CDTURLSession *)session
{
    NSParameterAssert(session);
    self = [super initWithDatabaseURL:databaseURL
                                 mode:mode
                            conflicts:includeConflicts
                         lastSequence:lastSequenceID
                               client:client
                              session:session];

    if(self){
        _session = session;
    }
    return self;
}


- (BOOL)start
{
    @synchronized (self) {
        if (self.task) return NO;

        os_log_info(CDTOSLog, "%{public}@: Starting...", [self class]);
        [super start];

        NSURL* url = self.changesFeedURL;
        self.request = [[NSMutableURLRequest alloc] initWithURL:url];
        self.request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        self.request.HTTPMethod = @"GET";

        // Add headers from my .requestHeaders property:
        for(NSString *key in self.requestHeaders) {
            [self.request setValue:self.requestHeaders[key] forHTTPHeaderField:key];
        }

        NSArray *requestHeadersKeys = [self.requestHeaders allKeys];

        if (self.authorizer) {
            NSString* authHeader = [self.authorizer authorizeURLRequest:self.request forRealm:nil];
            if (authHeader) {
                if ([requestHeadersKeys containsObject:@"Authorization"]) {
                    os_log_debug(CDTOSLog, "%{public}@ Overwriting 'Authorization' header with value %{public}@", self, authHeader);
                }
                [self.request setValue: authHeader forHTTPHeaderField:@"Authorization"];
            }
        }

        self.task = [self.session dataTaskWithRequest:self.request taskDelegate:self];

        [self.task resume];

        self.inputBuffer = [NSMutableData dataWithCapacity:0];

        self.startTime = [NSDate date];
        os_log_info(CDTOSLog, "%{public}@: Started... <%{public}@>", self, TDCleanURLtoString(url));
    }
    return YES;
}

- (void)clearConnection
{
    if(self.task.state != NSURLSessionTaskStateCompleted){
        [self.task cancel];
    }
    self.task = nil;
    self.inputBuffer = nil;
}

- (void)stop
{
    @synchronized (self) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(start)
                                                   object:nil];  // cancel pending retries
        if (self.task) {
            os_log_info(CDTOSLog, "%{public}@: stop", [self class]);
            [self clearConnection];
        }
        [super stop];
    }
}

- (void)retryOrError:(NSError*)error
{
    os_log_info(CDTOSLog, "%{public}@: retryOrError: %{public}@", [self class], error);
    if (++_retryCount <= kMaxRetries && TDMayBeTransientError(error)) {
        self.totalRetries++;
        [self clearConnection];
        NSTimeInterval retryDelay = kInitialRetryDelay * (1 << (_retryCount - 1));
        [self performSelector:@selector(start) withObject:nil afterDelay:retryDelay];
    } else {
        os_log_error(CDTOSLog, "%{public}@: Can't connect, giving up: %{public}@", self, error);
        
        self.error = error;
        [self stop];
    }
}

-(void)  URLSession:(NSURLSession *)session
               task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler{
    NSURLProtectionSpace *space = challenge.protectionSpace;
    NSString *authMethod = space.authenticationMethod;
    os_log_debug(CDTOSLog, "Got challenge for %{public}@: method=%{public}@, proposed=%{public}@, err=%{public}@", [self class], authMethod, challenge.proposedCredential, challenge.error);
    
    if ($equal(authMethod, NSURLAuthenticationMethodHTTPBasic)) {
        // On basic auth challenge, use proposed credential on first attempt. On second attempt,
        // or if there's no proposed credential, look one up. After that, continue without
        // credential and see what happens (probably a 401)
        
        if (challenge.previousFailureCount <= 1) {

            NSURLCredential *cred = challenge.proposedCredential;
            if (cred == nil || challenge.previousFailureCount > 0) {
                cred = [self.request.URL my_credentialForRealm:space.realm
                                          authenticationMethod:authMethod];
            }
            if (cred) {
                os_log_debug(CDTOSLog, "%{public}@ challenge: useCredential: %{public}@", [self class], cred);
                completionHandler(NSURLSessionAuthChallengeUseCredential,cred);
                // Update my authorizer so my owner (the replicator) can pick it up when I'm done
                _authorizer = [[TDBasicAuthorizer alloc] initWithCredential:cred];
                return;
            }
        }
        
        os_log_debug(CDTOSLog, "%{public}@ challenge: continueWithoutCredential", [self class]);
        completionHandler(NSURLSessionAuthChallengeUseCredential,nil);
    }
    else if ($equal(authMethod, NSURLAuthenticationMethodServerTrust)) {
        
        SecTrustRef trust = space.serverTrust;
        if ([TDRemoteRequest checkTrust:trust forHost:space.host]) {
            
            os_log_debug(CDTOSLog, "%{public}@ useCredential for trust: %{public}@", self, trust);
            NSURLCredential *cred = [NSURLCredential credentialForTrust:trust];
            completionHandler(NSURLSessionAuthChallengeUseCredential, cred);
            
        }
        else {
            os_log_debug(CDTOSLog, "%{public}@ challenge: cancel", self);
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
        }
    }
    else {
        os_log_debug(CDTOSLog, "%{public}@ challenge: performDefaultHandling", self);
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
    
}

-(void)receivedResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpresponse = (NSHTTPURLResponse *)response;
    TDStatus status = (TDStatus)httpresponse.statusCode;
    os_log_debug(CDTOSLog, "%{public}@: didReceiveResponse, status %{public}ld", [self class], (long)status);
    
    [self.inputBuffer setLength:0];

    if (TDStatusIsError(status)) {
        
        NSDictionary* errorInfo = nil;
        if (status == 401 || status == 407) {
            
            NSString* authorization = [self.requestHeaders objectForKey:@"Authorization"];
            NSString* authResponse = [httpresponse allHeaderFields][@"WWW-Authenticate"];
            
            os_log_error(CDTOSLog, "%{public}@: HTTP auth failed; sent Authorization: %{public}@  ;  got WWW-Authenticate: %{public}@", [self class], authorization, authResponse);
            errorInfo = $dict({ @"HTTPAuthorization", authorization },
                              { @"HTTPAuthenticateHeader", authResponse });
        }
        
        //retryOrError will only retry if the error seems to be a transient error.
        //otherwise, retryOrError will set the error and stop.
        [self retryOrError:TDStatusToNSErrorWithInfo(status, self.changesFeedURL, errorInfo)];
    }

    if (TDStatusIsError(((NSHTTPURLResponse *)response).statusCode)) {
        [self finishedLoading];
    }
}

-(void)receivedData:(NSData *)data
{
    os_log_debug(CDTOSLog, "%{public}@: didReceiveData: %{public}ld bytes", [self class], (unsigned long)[data length]);
    
    [self.inputBuffer appendData:data];
    [self finishedLoading];
}

-(void) finishedLoading
{
    //parse the input buffer into JSON (or NSArray of changes?)
    os_log_debug(CDTOSLog, "%{public}@: didFinishLoading, %{public}u bytes", self, (unsigned)self.inputBuffer.length);
    
    BOOL restart = NO;
    NSString* errorMessage = nil;
    NSInteger numChanges = [self receivedPollResponse:self.inputBuffer errorMessage:&errorMessage];
    
    if (numChanges < 0) {
        // unparseable response. See if it gets special handling:
        if ([self receivedDataBeginsCorrectly]) {
            
            // The response at least starts out as what we'd expect, so it looks like the connection
            // was closed unexpectedly before the full response was sent.
            NSTimeInterval elapsed = [self.startTime timeIntervalSinceNow] * -1.0;
            os_log_error(CDTOSLog, "%{public}@: connection closed unexpectedly after %{public}.1f sec. will retry", self, elapsed);
            
            [self retryOrError:[NSError errorWithDomain:NSURLErrorDomain
                                                   code:NSURLErrorNetworkConnectionLost
                                               userInfo:nil]];
            
            return;
        }
        
        // Otherwise report an upstream unparseable-response error
        [self setUpstreamError:errorMessage];
    }
    else {
        // Poll again if there was no error, and it looks like we
        // ran out of changes due to a _limit rather than because we hit the end.
        restart = numChanges == (NSInteger)_limit;
    }
    
    [self clearConnection];

    if (restart) {
        // Throttle the rate at which we get the list of changes. If we already have more than
        // kChangeQueueThreshold changes to be processed, wait until we fall below that threshold
        // before we get any more. Note that this is not a hard limit, and the number of changes may
        // exceed kChangeQueueThreshold, but it won't go vastly above the threshold. This saves us
        // from consuming large amounts of memory by allocating a TDPulledRevision for each
        // change we are waiting to pull and keeps our peak memory usage much smaller during
        // pulls of large numbers of changes.
        if ([_client respondsToSelector:@selector(sizeOfChangeQueue)]) {
            while ([_client sizeOfChangeQueue] > kChangeQueueThreshold &&
                   [[NSRunLoop currentRunLoop]
                          runMode:NSDefaultRunLoopMode
                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:kChangeQueuePollingRate]])
                ;
        }

        [self start];  // Next poll...
    } else {
        [self stopped];
    }
    
}

-(void) requestDidError:(NSError *)error
{
    [self retryOrError:error];
}

- (BOOL)receivedDataBeginsCorrectly
{
    NSString *prefixString = @"{\"results\":";
    NSData *prefixData = [prefixString dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger prefixLength = [prefixData length];
    NSUInteger inputLength = [self.inputBuffer length];
    BOOL match = NO;
    
    for (NSUInteger index = 0; index < inputLength; index++)
    {
        char currentChar;
        NSRange currentCharRange = NSMakeRange(index, 1);
        [self.inputBuffer getBytes:&currentChar range:currentCharRange];
        
        // If it's the opening {, check for valid start JSON
        if (currentChar == '{') {
            NSRange r = NSMakeRange(index, prefixLength);
            char buf[prefixLength];
            
            if (inputLength >= (index + prefixLength)) {  // enough data left
                [self.inputBuffer getBytes:buf range:r];
                match = (memcmp(buf, prefixData.bytes, prefixLength) == 0);
            }
            break;  // once we've seen a {, break always as can't succeed if we've not already.
        }
    }
    
    if (!match) {
        os_log_error(CDTOSLog, "%{public}@: Unparseable response from %{public}@. Did not find start of the expected response: %{public}@", self, TDCleanURLtoString(self.request.URL), prefixString);
    }
    
    return match;
}

@end
