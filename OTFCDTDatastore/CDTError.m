//
//  CDTError.m
//  CDTDatastore
//
//  Created by Miroslav Kutak on 23/07/21.
//  Copyright © 2021 IBM Corporation. All rights reserved.
//

#import "CDTError.h"

@implementation CDTError : NSObject

+ (NSError*)errorWith:(EncryptionError)errorCode {
    NSError *error;
    NSString *description = [self errorDescription: errorCode];
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setValue: description forKey: NSLocalizedDescriptionKey];

    switch (errorCode) {
        case NoFileFoundAtPath:
            error = [NSError errorWithDomain: NSBundle.mainBundle.bundleIdentifier code: errorCode userInfo: userInfo];
            break;
        case EncryptionAvailableAboveiOS9:
            error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code: errorCode userInfo: userInfo];
        default:
            break;
    }
    return error;
}


+(NSString*)errorDescription:(EncryptionError)errorCode {
    switch (errorCode) {
        case NoFileFoundAtPath:
            return @"There is no file found with the given name, Please check the name of the file again.";
            break;
        case EncryptionAvailableAboveiOS9:
            return @"Encryption feature is available for iOS 9 or later.";
            break;
        default:
            break;
    }
}

@end
