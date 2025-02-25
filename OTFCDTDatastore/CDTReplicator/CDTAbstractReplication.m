//
//  CDTAbstractReplication.m
//
//  Created by Adam Cox on 4/8/14.
//  Copyright (c) 2014 Cloudant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CDTAbstractReplication.h"
#import "CDTLogging.h"
#import "CDTSessionCookieInterceptor.h"
#import "TDRemoteRequest.h"
#import "TD_DatabaseManager.h"

NSString *const CDTReplicationErrorDomain = @"CDTReplicationErrorDomain";

@interface CDTAbstractReplication ()

NS_ASSUME_NONNULL_BEGIN
@property (nonnull, nonatomic, readwrite, strong) NSArray *httpInterceptors;

@property (nullable, readwrite, nonatomic, strong) NSString *username;
@property (nullable, readwrite, nonatomic, strong) NSString *password;
@property (nullable, readwrite, nonatomic, strong) NSString *IAMAPIKey;

NS_ASSUME_NONNULL_END

@end

@implementation CDTAbstractReplication

+ (NSString *)defaultUserAgentHTTPHeader { return [TDRemoteRequest userAgentHeader]; }

- (instancetype)copyWithZone:(NSZone *)zone
{
    CDTAbstractReplication *copy = [[[self class] allocWithZone:zone] init];
    if (copy) {
        copy.optionalHeaders = self.optionalHeaders;
        copy.httpInterceptors = [self.httpInterceptors copyWithZone:zone];
        copy.username = self.username;
        copy.password = self.password;
    }

    return copy;
}

NS_ASSUME_NONNULL_BEGIN

- (instancetype)init
{
    return [self initWithUsername:nil password: nil];
}

- (instancetype)initWithUsername:(nullable NSString *)username
                        password:(nullable NSString *)password
{
    self = [super init];
    if (self) {
        _httpInterceptors = @[];
        _username = username;
        _password = password;
    }
    return self;
}

- (instancetype)initWithIAMAPIKey:(NSString *)IAMAPIKey
{
    self = [super init];
    if (self) {
        _httpInterceptors = @[];
        _IAMAPIKey= IAMAPIKey;
    }
    return self;
}

/**
 * This method is a convience method and is the same as calling
 * -addinterceptors: with a single element array.
 */
- (void)addInterceptor:(NSObject<CDTHTTPInterceptor> *)interceptor
{
    [self addInterceptors:@[ interceptor ]];
}

/**
 * Appends the interceptors in the array to the list of
 * interceptors to run for each request made to the
 * server.
 *
 * @param interceptors the interceptors to append to the list
 **/
- (void)addInterceptors:(NSArray *)interceptors
{
    self.httpInterceptors = [self.httpInterceptors arrayByAddingObjectsFromArray:interceptors];
}

- (void)clearInterceptors { self.httpInterceptors = @[]; }
NS_ASSUME_NONNULL_END

/**
 Validates user supplied optional headers.
 */
+ (BOOL)validateOptionalHeaders:(NSDictionary *)candidateHeaders
                          error:(NSError *__autoreleasing *)error
{
    if (candidateHeaders) {
        NSMutableArray *lowercaseOptionalHeaders = [[NSMutableArray alloc] init];

        // check for strings
        for (id key in candidateHeaders) {
            if (![key isKindOfClass:[NSString class]]) {
                os_log_debug(CDTOSLog, "CDTAbstractReplication -validateOptionalHeaders Error: Replication HTTP header key is invalid (%{public}@).\n It must be NSString. Found type %{public}@",
                             key, [key class]);

                if (error) {
                    NSString *msg = @"Cannot sync data. Bad optional HTTP header.";
                    NSDictionary *userInfo =
                        @{NSLocalizedDescriptionKey : NSLocalizedString(msg, nil)};
                    *error = [NSError errorWithDomain:CDTReplicationErrorDomain
                                                 code:CDTReplicationErrorBadOptionalHttpHeaderType
                                             userInfo:userInfo];
                }
                return NO;
            }

            if (![candidateHeaders[key] isKindOfClass:[NSString class]]) {
                os_log_debug(CDTOSLog, "CDTAbstractReplication -validateOptionalHeaders Error: Value for replication HTTP header %{public}@ is invalid (%{public}@).\nIt must be NSString. Found type %{public}@.",
                             key, candidateHeaders[key], [candidateHeaders[key] class]);

                if (error) {
                    NSString *msg = @"Cannot sync data. Bad optional HTTP header.";
                    NSDictionary *userInfo =
                        @{NSLocalizedDescriptionKey : NSLocalizedString(msg, nil)};
                    *error = [NSError errorWithDomain:CDTReplicationErrorDomain
                                                 code:CDTReplicationErrorBadOptionalHttpHeaderType
                                             userInfo:userInfo];
                }
                return NO;
            }

            [lowercaseOptionalHeaders addObject:[(NSString *)key lowercaseString]];
        }

        NSArray *prohibitedHeaders = @[
            @"authorization",
            @"www-authenticate",
            @"host",
            @"connection",
            @"content-type",
            @"accept",
            @"content-length"
        ];

        NSMutableArray *badHeaders = [[NSMutableArray alloc] init];

        for (NSString *header in prohibitedHeaders) {
            if ([lowercaseOptionalHeaders indexOfObject:header] != NSNotFound) {
                [badHeaders addObject:header];
            }
        }

        if ([badHeaders count] > 0) {
            os_log_debug(CDTOSLog, "CDTAbstractionReplication -validateOptionalHeaders Error: You may not use these prohibited headers: %{public}@", badHeaders);

            if (error) {
                NSString *msg = @"Cannot sync data. Bad optional HTTP header.";
                NSDictionary *userInfo = @{NSLocalizedDescriptionKey : NSLocalizedString(msg, nil)};
                *error = [NSError errorWithDomain:CDTReplicationErrorDomain
                                             code:CDTReplicationErrorProhibitedOptionalHttpHeader
                                         userInfo:userInfo];
            }

            return NO;
        }
    }
    return YES;

}

- (BOOL)validateRemoteDatastoreURL:(NSURL *)url error:(NSError *__autoreleasing *)error
{
    NSString *scheme = [url.scheme lowercaseString];
    NSArray *validSchemes = @[ @"http", @"https" ];
    if (![validSchemes containsObject:scheme]) {
        os_log_debug(CDTOSLog, "%{public}@ -validateRemoteDatastoreURL Error. Invalid scheme: %{public}@",
                     [self class], url.scheme);

        if (error) {
            NSString *msg = @"Cannot sync data. Invalid Remote Database URL";

            NSDictionary *userInfo = @{NSLocalizedDescriptionKey : NSLocalizedString(msg, nil)};
            *error = [NSError errorWithDomain:CDTReplicationErrorDomain
                                         code:CDTReplicationErrorInvalidScheme
                                     userInfo:userInfo];
        }
        return NO;
    }

    // username and password must be supplied together
    BOOL usernameSupplied = url.user != nil && ![url.user isEqualToString:@""];
    BOOL passwordSupplied = url.password != nil && ![url.password isEqualToString:@""];

    if ((!usernameSupplied && passwordSupplied) || (usernameSupplied && !passwordSupplied)) {
        os_log_debug(CDTOSLog, "%{public}@ -validateRemoteDatastoreURL Error. Must have both username and password, or neither. ", [self class]);

        if (error) {
            NSString *msg =
                [NSString stringWithFormat:@"Cannot sync data. Missing %@",
                                           usernameSupplied ? @"password" : @"username"];

            NSDictionary *userInfo = @{NSLocalizedDescriptionKey : NSLocalizedString(msg, nil)};
            *error = [NSError errorWithDomain:CDTReplicationErrorDomain
                                         code:CDTReplicationErrorIncompleteCredentials
                                     userInfo:userInfo];
        }
        return NO;
    }

    return YES;
}

@end
