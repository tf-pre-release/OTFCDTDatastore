//
//  CDTQIndexCreator.h
//
//  Created by Michael Rhodes on 29/09/2014.
//  Copyright (c) 2014 Cloudant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <Foundation/Foundation.h>
#import "CDTQIndex.h"

@class FMDatabaseQueue;
@class CDTDatastore;
@class CDTQSqlParts;

NS_ASSUME_NONNULL_BEGIN

@interface CDTQIndexCreator : NSObject

/**
 Add a single, possibly compound, index for the given field names.

 @param index List of fieldnames in the sort format
 @param database Database in which index should be created..
 @param datastore The source datastore.
 */
+ (nullable NSString *)ensureIndexed:(CDTQIndex *)index
                          inDatabase:(FMDatabaseQueue *)database
                       fromDatastore:(CDTDatastore *)datastore;

+ (NSArray /*NSDictionary or NSString*/ *)removeDirectionsFromFields:(NSArray *)fieldNames;

+ (BOOL)validFieldName:(NSString *)fieldName;

+ (nullable NSArray<CDTQSqlParts *> *)
insertMetadataStatementsForIndexName:(NSString *)indexName
                                type:(NSString *)indexType
                            settings:(nullable NSString *)indexSettings
                          fieldNames:(NSArray<NSString *> *)fieldNames;

+ (nullable CDTQSqlParts *)createIndexTableStatementForIndexName:(NSString *)indexName
                                                      fieldNames:(NSArray<NSString *> *)fieldNames;

+ (nullable CDTQSqlParts *)createIndexIndexStatementForIndexName:(NSString *)indexName
                                                      fieldNames:(NSArray<NSString *> *)fieldNames;

+ (nullable CDTQSqlParts *)
createVirtualTableStatementForIndexName:(NSString *)indexName
                             fieldNames:(NSArray<NSString *> *)fieldNames
                               settings:
                                   (nullable NSDictionary<NSString *, NSString *> *)indexSettings;

@end

NS_ASSUME_NONNULL_END
