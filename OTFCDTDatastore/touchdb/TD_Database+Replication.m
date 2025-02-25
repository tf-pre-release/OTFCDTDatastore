//
//  TD_Database+Replication.m
//  TouchDB
//
//  Created by Jens Alfke on 12/27/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Modifications for this distribution by Cloudant, Inc., Copyright (c) 2014 Cloudant, Inc.
//  Copyright © 2016 IBM Corporation. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TD_Database+Replication.h"
#import "TDInternal.h"
#import "TDPuller.h"
#import "TDJSON.h"
#import "CollectionUtils.h"

#import <fmdb/FMDatabase.h>
#import <fmdb/FMDatabaseAdditions.h>
#import <fmdb/FMDatabaseQueue.h>

#define kActiveReplicatorCleanupDelay 10.0

@implementation TD_Database (Replication)

- (NSArray *)activeReplicators { return _activeReplicators; }

- (void)addActiveReplicator:(TDReplicator *)repl
{
    if (!_activeReplicators) {
        _activeReplicators = [[NSMutableArray alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(replicatorDidStop:)
                                                     name:TDReplicatorStoppedNotification
                                                   object:nil];
    }
    if (![_activeReplicators containsObject:repl]) [_activeReplicators addObject:repl];
}

- (TDReplicator *)activeReplicatorLike:(TDReplicator *)repl
{
    for (TDReplicator *activeRepl in _activeReplicators) {
        if ([activeRepl hasSameSettingsAs:repl]) return activeRepl;
    }
    return nil;
}

- (void)stopAndForgetReplicator:(TDReplicator *)repl
{
    [repl databaseClosing];
    [_activeReplicators removeObjectIdenticalTo:repl];
}

- (void)replicatorDidStop:(NSNotification *)n
{
    TDReplicator *repl = n.object;
    if (repl.error)  // Leave it around a while so clients can see the error
        [_activeReplicators performSelector:@selector(removeObjectIdenticalTo:)
                                 withObject:repl
                                 afterDelay:kActiveReplicatorCleanupDelay];
    else
        [_activeReplicators removeObjectIdenticalTo:repl];
}

- (NSDictionary<NSString *, NSObject *> *)checkpointDocumentWithID:(NSString *)checkpointID
{
    NSParameterAssert(checkpointID);

    // This table schema is out of date but I'm keeping it the way it is for compatibility.
    // The 'remote' column now stores the opaque checkpoint IDs, and 'push' is ignored.
    __block NSData *lastSequenceJson = nil;
    [_fmdbQueue inDatabase:^(FMDatabase *db) {
        lastSequenceJson = [db
            dataForQuery:@"SELECT last_sequence FROM replicators WHERE remote=?", checkpointID];
        
    }];
    if (lastSequenceJson != nil) {
        NSDictionary *lastSequence = [TDJSON JSONObjectWithData:lastSequenceJson options:0 error:nil];
        // the sequence is saved as a json dict of {"seq": <data>}
        return lastSequence;
    } else {
        return nil;
    }
}

- (BOOL)saveCheckpointDocument:(NSDictionary<NSString *, NSObject *> *)checkpoint
                         error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(checkpoint);
    NSParameterAssert(checkpoint.count > 0);

    NSString *remote = (NSString *)checkpoint[@"_id"];
    // 7 is the length of _local/
    remote = [remote substringFromIndex:7];

    NSData *checkpointData = [TDJSON dataWithJSONObject:checkpoint options:0 error:error];
    if (!checkpointData) {
        return NO;
    }

    __block bool result;
    [self.fmdbQueue inDatabase:^(FMDatabase *db) {
      result = [db executeUpdate:@"INSERT OR REPLACE INTO replicators (remote, push, "
                        @"last_sequence) VALUES (?, -1, ?)"
          withErrorAndBindings:error, remote, checkpointData];
    }];

    return result;
}

+ (NSString *)joinQuotedStrings:(NSArray *)strings
{
    if (strings.count == 0) return @"";
    NSMutableString *result = [NSMutableString stringWithString:@"'"];
    BOOL first = YES;
    for (NSString *str in strings) {
        if (first)
            first = NO;
        else
            [result appendString:@"','"];
        NSRange range = NSMakeRange(result.length, str.length);
        [result appendString:str];
        [result replaceOccurrencesOfString:@"'"
                                withString:@"''"
                                   options:NSLiteralSearch
                                     range:range];
    }
    [result appendString:@"'"];
    return result;
}

- (BOOL)findMissingRevisions:(TD_RevisionList *)revs
{
    if (revs.count == 0) return YES;

    __block BOOL result = YES;
    [_fmdbQueue inDatabase:^(FMDatabase *db) {
        NSString *sql = $sprintf(@"SELECT docid, revid FROM revs, docs "
                                  "WHERE revid in (%@) AND docid IN (%@) "
                                  "AND revs.doc_id == docs.doc_id",
                                 [TD_Database joinQuotedStrings:revs.allRevIDs],
                                 [TD_Database joinQuotedStrings:revs.allDocIDs]);
        // ?? Not sure sqlite will optimize this fully. May need a first query that looks up all
        // the numeric doc_ids from the docids.
        FMResultSet *r = [db executeQuery:sql];
        if (!r) {
            result = NO;
            return;
        }
        while ([r next]) {
            @autoreleasepool
            {
                TD_Revision *rev =
                    [revs revWithDocID:[r stringForColumnIndex:0] revID:[r stringForColumnIndex:1]];
                if (rev) {
                    [revs removeRev:rev];
                }
            }
        }
        [r close];
    }];
    return result;
}

@end
