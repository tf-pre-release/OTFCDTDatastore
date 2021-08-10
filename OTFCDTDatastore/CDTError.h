//
//  CDTError.h
//  CDTDatastore
//
//  Created by Miroslav Kutak on 23/07/21.
//  Copyright © 2021 IBM Corporation. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CDTError: NSObject

typedef NS_ENUM(NSInteger, EncryptionError) {
    NoFileFoundAtPath = 1001,
    EncryptionAvailableAboveiOS9 = 1002
};


+ (NSError*)errorWith:(EncryptionError)errorCode;

@end

NS_ASSUME_NONNULL_END
