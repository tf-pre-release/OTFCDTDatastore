//
//  CDTSessionCookieInterceptorBase.m
//  CDTDatastore
//
//  Created by tomblench on 05/07/2017.
//  Copyright © 2017 IBM Corporation. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//

#import "CDTSessionCookieInterceptorBase.h"
#import "CDTLogging.h"

#import <os/log.h>

/** Number of seconds to wait for _session to respond. */
static const NSInteger CDTSessionCookieRequestTimeout = 600;


@implementation CDTSessionCookieInterceptorBase


- (instancetype)init
{
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
        [self setShouldMakeSessionRequest:YES];
        // allow sub-classes to set headers etc for the session
        config = [self customiseSessionConfig:config];
        [self setUrlSession:[NSURLSession sessionWithConfiguration:config]];
    }
    return self;
}

- (NSURLSessionConfiguration*)customiseSessionConfig:(NSURLSessionConfiguration*)config
{
    // sub-classes may wish to over-ride this
    return config;
}

- (BOOL)hasValidCookieWithName:(nonnull NSString*)cookieName forRequestURL:(nonnull NSURL*)requestUrl
{
    os_log_debug(CDTOSLog, "Checking cookies.");
    
    if (@available(iOS 10.0, macOS 10.12, tvOS 10.0, watchOS 3.0, *)) {
        const char *msg = @"Checking cookies.".UTF8String;
        os_log_debug(OS_LOG_DEFAULT, "%{public}s", msg);
    }
    // Get the existing cookies
    // Compare them to the current time and return YES if we should renew
    NSDate *timeNow = [NSDate date];
    for (NSHTTPCookie* c in _cookies)
    {
        if ([c.name isEqualToString: cookieName]) {
            os_log_debug(CDTOSLog, "Already have %{public}@ cookie.", cookieName);
            if ([c.expiresDate timeIntervalSinceDate: timeNow] > [@300.0 doubleValue]) {
                // It is more than 5 minutes until the session expires
                os_log_debug(CDTOSLog, "%{public}@ cookie is still valid.", cookieName);
                return YES;
            } else {
                os_log_debug(CDTOSLog, "%{public}@ cookie is expired or expiring soon.", cookieName);
            }
        }
    }
    os_log_debug(CDTOSLog, "Will attempt to get new %{public}@ cookie.", cookieName);
    return NO;
}

/**
 We assume a 401 means that the cookie we applied at request time was rejected. Therefore
 clear it and tell the HTTP mechanism to retry the request. For all other responses, there's
 nothing for this interceptor to do.
 */
- (CDTHTTPInterceptorContext *)interceptResponseInContext:(CDTHTTPInterceptorContext *)context
{
    bool retryAndAttemptNewSession = NO;
    if (self.shouldMakeSessionRequest) {
        if (context.response.statusCode == 401) {
            retryAndAttemptNewSession = YES;
        } else if (context.response.statusCode == 403) {
            NSError *error = nil;
            NSDictionary *statusCodeMessage = [NSJSONSerialization JSONObjectWithData:context.responseData
                                                                              options:0
                                                                                error:&error];
            if(!error) {
                NSString *http403Error = [statusCodeMessage objectForKey:@"error"];
                if([http403Error isEqualToString:@"credentials_expired"]) {
                   retryAndAttemptNewSession = YES;
                }
            }
        }
    }
    
    if (retryAndAttemptNewSession) {
        // Clear the cookies as we are no longer authorized
        _cookies = nil;
        context.shouldRetry = YES;
    }

    // A sliding window may send an early cookie refresh which may save us a _session round-trip
    if (context.response.allHeaderFields[@"Set-Cookie"]) {
        // Replace the cookies with any sent on the response
        self.cookies = [NSHTTPCookie cookiesWithResponseHeaderFields: context.response.allHeaderFields forURL:context.request.URL];
    }

    return context;
}


/**
 Handles retrieving a cookie ("logging in") for the credentials this interceptor
 was initialised with.
 
 If the request fails, this method will also set the `shouldMakeSessionRequest` property
 to `NO` if the error didn't look transient.
 */
- (nullable NSArray<NSHTTPCookie *> *)startNewSessionAtURL:(NSURL *)url
                                   withBody:(NSData *)body
                                    session:(NSURLSession *)session
                      sessionStartedHandler:(BOOL (^)(NSData *data))sessionStartedHandler
{
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    // We store the cookies ourselves so we shouldn't use the default handling
    request.HTTPShouldHandleCookies = NO;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSArray<NSHTTPCookie*> *cookies = nil;
    NSURLSessionDataTask *task = [session
                                  dataTaskWithRequest:request
                                  completionHandler:^(NSData *__nullable data, NSURLResponse *__nullable response,
                                                      NSError *__nullable error) {
                                      
                                      NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                                      
                                      if (httpResp && httpResp.statusCode / 100 == 2) {
                                          // Success!
                                          // Store the cookie value from the header
                                          if (data && sessionStartedHandler(data)) {
                                              cookies = [NSHTTPCookie cookiesWithResponseHeaderFields: httpResp.allHeaderFields forURL:request.URL];
                                              os_log_debug(CDTOSLog, "Got cookie");
                                          }
                                      } else if (!httpResp) {
                                          // Network failure of some kind; often transient. Try again next time.
                                          os_log_error(CDTOSLog, "Error making cookie response, error:%{public}@",
                                                       [error localizedDescription]);
                                      } else if (httpResp.statusCode / 100 == 5) {
                                          // Server error of some kind; often transient. Try again next time.
                                          os_log_error(CDTOSLog, "Failed to get cookie from the server at %{public}@, response code was %{public}ld.",
                                                       url, (long)httpResp.statusCode);
                                      } else if (httpResp.statusCode == 401) {
                                          // Credentials are not valid, fail and don't retry.
                                          os_log_error(CDTOSLog, "Credentials are incorrect, cookie authentication will not be attempted again by this interceptor object");
                                          self.shouldMakeSessionRequest = NO;
                                      } else {
                                          // Most other HTTP status codes are non-transient failures; don't retry.
                                          NSString *dataJsonResponse = [[NSString alloc] initWithData:data
                                                                                             encoding:NSUTF8StringEncoding];
                                          if(dataJsonResponse) {
                                              os_log_error(CDTOSLog, "Failed to get cookie from the server at %{public}@, response code %{public}ld, response message: %{public}@. Cookie authentication will not be attempted again by this interceptor object",
                                                           url, (long)httpResp.statusCode, dataJsonResponse);
                                          } else {
                                              os_log_error(CDTOSLog, "Failed to get cookie from the server at %{public}@, response code %{public}ld. Cookie authentication will not be attempted again by this interceptor object",
                                                           url, (long)httpResp.statusCode);
                                          }
                                          self.shouldMakeSessionRequest = NO;
                                      }
                                      
                                      dispatch_semaphore_signal(sema);
                                      
                                  }];
    [task resume];
    dispatch_semaphore_wait(
                            sema, dispatch_time(DISPATCH_TIME_NOW, CDTSessionCookieRequestTimeout * NSEC_PER_SEC));
    return cookies;
}

@end
