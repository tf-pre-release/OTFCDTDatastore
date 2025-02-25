//
// TD_Database.m
// TouchDB
//
// Created by Jens Alfke on 6/19/10.
// Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
// Modified by Michael Rhodes, 2013
// Copyright (c) 2013 Cloudant, Inc. All rights reserved.
//
// Copyright © 2017, 2018 IBM Corporation. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//
//  Modifications for this distribution by Cloudant, Inc., Copyright (c) 2014 Cloudant, Inc.

#import <sqlite3.h>
#import "TD_Database.h"
#import "TD_Database+Attachments.h"
#import "TD_Database+BlobFilenames.h"
#import "TDInternal.h"
#import "TD_Revision.h"
#import "TDCollateJSON.h"
#import "TDBlobStore.h"
#import "TDMisc.h"
#import "TDJSON.h"
#import "Test.h"

#import <fmdb/FMDatabase.h>
#import <fmdb/FMDatabaseAdditions.h>
#import "FMDatabase+LongLong.h"
#import "FMDatabase+EncryptionKey.h"
#import <fmdb/FMDatabaseQueue.h>
#import "CDTEncryptionKeyProvider.h"
#import "CDTLogging.h"

NSString* const TD_DatabaseWillCloseNotification = @"TD_DatabaseWillClose";
NSString* const TD_DatabaseWillBeDeletedNotification = @"TD_DatabaseWillBeDeleted";

//@interface FMDatabaseCreator : NSObject
//@end
//@implementation FMDatabaseCreator
//+ (FMDatabase*)databaseWithPath:(NSString*)path {
//    FMDatabase* db = [FMDatabase databaseWithPath:path];
//
//    db.busyRetryTimeout = 10;
//#if DEBUG
//    db.logsErrors = YES;
//#else
//    db.logsErrors = WillLogTo(TD_Database);
//#endif
//    db.traceExecution = WillLogTo(TD_DatabaseVerbose);
//
//    NSLog(@"Returning custom FMDB");
//
//    return db;
//}
//@end
//
//@interface CustomFMDatabaseQueue : FMDatabaseQueue
//@end
//@implementation CustomFMDatabaseQueue
//+ (Class)databaseClass {
//    return [FMDatabaseCreator class];
//}
//@end

@interface TD_Database()

@property (nonatomic) dispatch_queue_t queue;
@property (atomic, getter=isOpen) BOOL open;


@end

@implementation TD_Database

@synthesize fmdbQueue = _fmdbQueue;


static BOOL removeItemIfExists(NSString* path, NSError** outError)
{
    NSFileManager* fmgr = [NSFileManager defaultManager];
    return [fmgr removeItemAtPath:path error:outError] || ![fmgr fileExistsAtPath:path];
}

- (NSString*)attachmentStorePath
{
    return [TD_Database attachmentStorePathWithDatabasePath:_path];
}

+ (NSString *)attachmentStorePathWithDatabasePath:(NSString *)path
{
    return [[path stringByDeletingPathExtension] stringByAppendingString:@" attachments"];
}

+ (instancetype)createEmptyDBAtPath:(NSString*)path
          withEncryptionKeyProvider:(id<CDTEncryptionKeyProvider>)provider
{
    if (!removeItemIfExists(path, NULL)) return nil;
    TD_Database* db = [[self alloc] initWithPath:path];
    if (!removeItemIfExists(db.attachmentStorePath, NULL)) return nil;
    if (![db openWithEncryptionKeyProvider:provider]) return nil;
    return db;
}

- (instancetype)initWithPath:(NSString*)path
{
    if (self = [super init]) {
        Assert([path hasPrefix:@"/"], @"Path must be absolute");
        _path = [path copy];
        _name = [path.lastPathComponent.stringByDeletingPathExtension copy];

        if (0) {
            // Appease the static analyzer by using these category ivars in this source file:
            _validations = nil;
            _pendingAttachmentsByDigest = nil;
        }
        _queue = dispatch_queue_create("com.cloudant.sync.db", NULL); //Serial dispatch queue.
    }
    return self;
}

- (NSString*)description { return $sprintf(@"%@[%@]", [self class], _path); }

- (BOOL)exists { return [TD_Database existsDatabaseAtPath:_path]; }

+ (BOOL)existsDatabaseAtPath:(NSString *)path
{
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (BOOL)replaceWithDatabaseFile:(NSString*)databasePath
                withAttachments:(NSString*)attachmentsPath
                          error:(NSError**)outError
{
    Assert(![self isOpen], @"Already-open database cannot be replaced");
    NSString* dstAttachmentsPath = self.attachmentStorePath;
    NSFileManager* fmgr = [NSFileManager defaultManager];
    return [fmgr copyItemAtPath:databasePath toPath:_path error:outError] &&
           removeItemIfExists(dstAttachmentsPath, outError) &&
           (!attachmentsPath ||
            [fmgr copyItemAtPath:attachmentsPath toPath:dstAttachmentsPath error:outError]);
}

#pragma mark - OPENING AND MIGRATING DB SCHEMA

// caller: -open Must run in FMDatabaseQueue block
- (BOOL)migrateWithUpdates:(NSString*)updates
                   queries:(NSString*)queries
                   version:(NSInteger)version
                inDatabase:(FMDatabase*)db
{
    if (nil != updates) {
        for (NSString* statement in [updates componentsSeparatedByString:@";"]) {
            if (statement.length && ![db executeUpdate:statement]) {
                os_log_debug(CDTOSLog, "TD_Database: Could not initialize schema of %{public}@ -- May be an old/incompatible format. SQLite error: %{public}@", _path, db.lastErrorMessage);
                [db close];
                return NO;
            }
        }
    }

    if (nil != queries) {
        for (NSString* statement in [queries componentsSeparatedByString:@";"]) {
            // We should be able to ignore the results of migration queries, unless there's a
            // problem in which case it's nil.
            FMResultSet* results = [db executeQuery:statement];
            if (statement.length && results == nil) {
                os_log_debug(CDTOSLog, "TD_Database: Could not initialize schema of %{public}@ -- May be an old/incompatible format. SQLite error: %{public}@",_path, db.lastErrorMessage);
                [db close];
                return NO;
            }
            [results close];
        }
    }
    // at the end, update user_version
    NSString* statement = [NSString stringWithFormat:@"PRAGMA user_version = %li", (long)version];
    if (statement.length && ![db executeUpdate:statement]) {
        os_log_debug(CDTOSLog, "TD_Database: Could not initialize schema of %{public}@ -- May be an old/incompatible format. SQLite error: %{public}@", _path, db.lastErrorMessage);
        [db close];
        return NO;
    }

    return YES;
}

// caller: -openFMDBWithEncryptionKeyProvider: Must run in FMDatabaseQueue block
- (BOOL)initialize:(NSString*)updates inDatabase:(FMDatabase*)db
{
    if (nil != updates) {
        for (NSString* statement in [updates componentsSeparatedByString:@";"]) {
            if (statement.length && ![db executeUpdate:statement]) {
                os_log_debug(CDTOSLog, "TD_Database: Could not initialize schema of %{public}@ -- May be an old/incompatible format. SQLite error: %{public}@", _path, db.lastErrorMessage);
                [db close];
                return NO;
            }
        }
    }

    return YES;
}

// callers: -open, -compact
- (BOOL)openFMDBWithEncryptionKeyProvider:(id<CDTEncryptionKeyProvider>)provider
{
    __block BOOL result = YES;


    dispatch_sync(self.queue, ^{
        // Create database
        FMDatabaseQueue* queue = nil;

        if (result) {
            queue = [TD_Database queueForDatabaseAtPath:_path readOnly:_readOnly];

            result = (queue != nil);
        }

        // Set key to cipher database (if available)
        if (result) {
            [queue inDatabase:^(FMDatabase* db) {
                NSError* error = nil;
                result = [db setKeyWithProvider:provider error:&error];
                if (!result) {
                    os_log_error(CDTOSLog, "Key not set for DB at %{public}@: %{public}@", self->_path, error);
                }
            }];
        }

        // Register CouchDB-compatible JSON collation functions:
        if (result) {
            [queue inDatabase:^(FMDatabase* db) {
                sqlite3_create_collation(db.sqliteHandle, "JSON", SQLITE_UTF8, kTDCollateJSON_Unicode,
                        TDCollateJSON);
                sqlite3_create_collation(db.sqliteHandle, "JSON_RAW", SQLITE_UTF8, kTDCollateJSON_Raw,
                        TDCollateJSON);
                sqlite3_create_collation(db.sqliteHandle, "JSON_ASCII", SQLITE_UTF8, kTDCollateJSON_ASCII,
                        TDCollateJSON);
                sqlite3_create_collation(db.sqliteHandle, "REVID", SQLITE_UTF8, NULL, TDCollateRevIDs);
            }];
        }

        // Stuff we need to initialize every time the database opens:
        if (result) {
            __weak TD_Database* weakSelf = self;
            [queue inDatabase:^(FMDatabase* db) {
                TD_Database* strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf initialize:@"PRAGMA foreign_keys = ON;" inDatabase:db]) {
                    result = NO;
                }
            }];
        }

        // Assign properties (if everything was OK)
        if (result) {
            _fmdbQueue = queue;
            _keyProviderToOpenDB = provider;
        } else if (queue) {
            [queue close];
        }

    });


    return result;
}

// callers: many things
- (BOOL)isOpenWithEncryptionKeyProvider:(id<CDTEncryptionKeyProvider>)provider
{
    BOOL isValid = NO;
    
    if ([self isOpen]) {
        isValid = [TD_Database sameEncryptionKeyIn:_keyProviderToOpenDB and:provider];
        
        if (!isValid) {
            os_log_error(CDTOSLog, "DB is open but key provided is wrong");
        }
    }
    
    return isValid;
}

// callers: -isOpenWithEncryptionKeyProvider:
+ (BOOL)sameEncryptionKeyIn:(id<CDTEncryptionKeyProvider>)thisProvider
                        and:(id<CDTEncryptionKeyProvider>)otherProvider
{
    CDTEncryptionKey *thisKey = [thisProvider encryptionKey];
    CDTEncryptionKey *otherKey = [otherProvider encryptionKey];
    
    BOOL sameKey = NO;
    if (thisKey == nil) {
        sameKey = (otherKey == nil);
    } else {
        sameKey = ((otherKey != nil) && [otherKey isEqualToEncryptionKey:thisKey]);
    }

    return sameKey;
}

// callers: many things
- (BOOL)openWithEncryptionKeyProvider:(id<CDTEncryptionKeyProvider>)provider
{
    Assert(provider, @"Key provider is mandatory. Supply a CDTNilEncryptionKeyProvider instead.");
    
    if ([self isOpen]) {
         return [self isOpenWithEncryptionKeyProvider:provider];
    }
    
    if (![self openFMDBWithEncryptionKeyProvider:provider]) {
        return NO;
    }

    __block BOOL result = YES;
    __weak TD_Database* weakSelf = self;
    [self.fmdbQueue inTransaction:^(FMDatabase* db, BOOL* rollback) {
        TD_Database* strongSelf = weakSelf;

        // Transaction will be rolled back unless, rollback is changed to NO.
        *rollback = YES;

        // Check the user_version number we last stored in the database:
        int dbVersion = [db intForQuery:@"PRAGMA user_version"];

        // Incompatible version changes increment the hundreds' place:
        if (dbVersion >= 300) {
            os_log_debug(CDTOSLog, "TD_Database: Database version (%{public}d) is newer than I know how to work with", dbVersion);
            [db close];
            result = NO;
            return;
        }

        if (dbVersion < 1) {
            // First-time initialization:
            // (Note: Declaring revs.sequence as AUTOINCREMENT means the values will always be
            // monotonically increasing, never reused. See <http://www.sqlite.org/autoinc.html>)
            NSString* schema = @"\
                CREATE TABLE docs ( \
                    doc_id INTEGER PRIMARY KEY, \
                    docid TEXT UNIQUE NOT NULL); \
                CREATE INDEX docs_docid ON docs(docid); \
                CREATE TABLE revs ( \
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, \
                    doc_id INTEGER NOT NULL REFERENCES docs(doc_id) ON DELETE CASCADE, \
                    revid TEXT NOT NULL COLLATE REVID, \
                    parent INTEGER REFERENCES revs(sequence) ON DELETE SET NULL, \
                    current BOOLEAN, \
                    deleted BOOLEAN DEFAULT 0, \
                    json BLOB, \
                    UNIQUE (doc_id, revid)); \
                CREATE INDEX revs_current ON revs(doc_id, current); \
                CREATE INDEX revs_parent ON revs(parent); \
                CREATE TABLE localdocs ( \
                    docid TEXT UNIQUE NOT NULL, \
                    revid TEXT NOT NULL COLLATE REVID, \
                    json BLOB); \
                CREATE INDEX localdocs_by_docid ON localdocs(docid); \
                CREATE TABLE views ( \
                    view_id INTEGER PRIMARY KEY, \
                    name TEXT UNIQUE NOT NULL,\
                    version TEXT, \
                    lastsequence INTEGER DEFAULT 0); \
                CREATE INDEX views_by_name ON views(name); \
                CREATE TABLE maps ( \
                    view_id INTEGER NOT NULL REFERENCES views(view_id) ON DELETE CASCADE, \
                    sequence INTEGER NOT NULL REFERENCES revs(sequence) ON DELETE CASCADE, \
                    key TEXT NOT NULL COLLATE JSON, \
                    value TEXT); \
                CREATE INDEX maps_keys on maps(view_id, key COLLATE JSON); \
                CREATE TABLE attachments ( \
                    sequence INTEGER NOT NULL REFERENCES revs(sequence) ON DELETE CASCADE, \
                    filename TEXT NOT NULL, \
                    key BLOB NOT NULL, \
                    type TEXT, \
                    length INTEGER NOT NULL, \
                    revpos INTEGER DEFAULT 0); \
                CREATE INDEX attachments_by_sequence on attachments(sequence, filename); \
                CREATE TABLE replicators ( \
                    remote TEXT NOT NULL, \
                    push BOOLEAN, \
                    last_sequence TEXT, \
                    UNIQUE (remote, push))";
            if (![strongSelf migrateWithUpdates:schema queries:nil version:3 inDatabase:db]) {
                result = NO;
                return;
            }
            dbVersion = 3;
        }

        if (dbVersion < 2) {
            // Version 2: added attachments.revpos
            NSString* sql = @"ALTER TABLE attachments ADD COLUMN revpos INTEGER DEFAULT 0";
            if (![strongSelf migrateWithUpdates:sql queries:nil version:2 inDatabase:db]) {
                result = NO;
                return;
            }
            dbVersion = 2;
        }

        if (dbVersion < 3) {
            // Version 3: added localdocs table
            NSString* sql = @"CREATE TABLE IF NOT EXISTS localdocs ( \
                                docid TEXT UNIQUE NOT NULL, \
                                revid TEXT NOT NULL, \
                                json BLOB); \
                                CREATE INDEX IF NOT EXISTS localdocs_by_docid ON localdocs(docid)";
            if (![strongSelf migrateWithUpdates:sql queries:nil version:3 inDatabase:db]) {
                result = NO;
                return;
            }
            dbVersion = 3;
        }

        if (dbVersion < 4) {
            // Version 4: added 'info' table
            NSString* sql = $sprintf(@"CREATE TABLE info ( \
                                         key TEXT PRIMARY KEY, \
                                         value TEXT); \
                                       INSERT INTO INFO (key, value) VALUES ('privateUUID', '%@');\
                                       INSERT INTO INFO (key, value) VALUES ('publicUUID',  '%@')",
                                     TDCreateUUID(), TDCreateUUID());
            if (![strongSelf migrateWithUpdates:sql queries:nil version:4 inDatabase:db]) {
                result = NO;
                return;
            }
            dbVersion = 4;
        }

        if (dbVersion < 5) {
            // Version 5: added encoding for attachments
            NSString* sql = @"ALTER TABLE attachments ADD COLUMN encoding INTEGER DEFAULT 0; \
                              ALTER TABLE attachments ADD COLUMN encoded_length INTEGER";
            if (![strongSelf migrateWithUpdates:sql queries:nil version:5 inDatabase:db]) {
                result = NO;
                return;
            }
            dbVersion = 5;
        }

        if (dbVersion < 6) {
            // Version 6: enable Write-Ahead Log (WAL) <http://sqlite.org/wal.html>
            NSString* sql = @"PRAGMA journal_mode=WAL";
            if (![strongSelf migrateWithUpdates:nil queries:sql version:6 inDatabase:db]) {
                result = NO;
                return;
            }
            dbVersion = 6;
        }
        
        if (dbVersion < 100) {
            // Version 100: upgrade replicators.last_sequence to a json dict of {"seq": <data>}
            FMResultSet *replicators = [db executeQuery:@"SELECT rowid, last_sequence FROM replicators"];
            
            while ([replicators next]) {
                NSUInteger rowid = [replicators longForColumn:@"rowid"];
                NSData *lastSequence = [replicators dataForColumn:@"last_sequence"];
                NSDictionary *lastSequenceJsonMaybe = [TDJSON JSONObjectWithData:lastSequence options:0 error:nil];
                if (lastSequenceJsonMaybe == nil) {
                    // sequence not in json format, so upgrade it
                    NSString *lastSequenceString = [replicators stringForColumn:@"last_sequence"];
                    // the sequence might have been a number, or a string "<number-base64>"
                    NSDictionary *dict = @{@"seq": lastSequenceString};
                    NSData *lastSequenceJson = [TDJSON dataWithJSONObject:dict options:0 error:nil];
                    [db executeUpdate:@"UPDATE replicators SET last_sequence=? WHERE rowid=?", lastSequenceJson, @(rowid)];
                }
            }
            
            // upgrade the schema version without any updates (since our updates were in the code above)
            if (![strongSelf migrateWithUpdates:nil queries:nil version:100 inDatabase:db]) {
                result = NO;
                return;
            }
            dbVersion = 100;
        }

        if (dbVersion < 200) {
            // Version 200: Table which maps key to filename
            NSString* sql = [TD_Database sqlCommandToCreateBlobFilenamesTable];
            if (![strongSelf migrateWithUpdates:sql queries:nil version:200 inDatabase:db]) {
                result = NO;
                return;
            }
            
            // Populate table
            FMResultSet *attachmentKeys = [db executeQuery:@"SELECT DISTINCT key FROM attachments"];
            
            while ([attachmentKeys next]) {
                NSData *keyData = [attachmentKeys dataNoCopyForColumn:@"key"];
                
                NSString* filename = [TD_Database generateAndInsertFilenameBasedOnKey:*(TDBlobKey *)keyData.bytes
                                                     intoBlobFilenamesTableInDatabase:db];

                if (!filename) {
                    result = NO;
                    return;
                }
            }
            
            // dbVersion = 200;
        }
        
#if DEBUG
        db.crashOnErrors = YES;
#endif
        
        // Open attachment store:
        NSString* attachmentsPath = strongSelf.attachmentStorePath;
        NSError* error;
        self->_attachments = [[TDBlobStore alloc] initWithPath:attachmentsPath
                                         encryptionKeyProvider:provider
                                                         error:&error];
        if (!self->_attachments) {
            os_log_debug(CDTOSLog, "%{public}@: Couldn't open attachment store at %{public}@",
                         self, self.attachmentStorePath);
            [db close];
            result = NO;
            return;
        }

        // Transaction has completed successfully, setting rollback to NO to prevent rollback.
        *rollback = NO;
    }];
    
    if (result) {
        self.open = YES;
        return YES;
    } else {
        return NO;
    }
}

#pragma mark Closing and deleting database
- (BOOL)close
{

    __block BOOL result;
    dispatch_sync(self.queue, ^{
        result = [self closeInternal];
    });

    return result;
}

/**
 *  Closes the database, this **MUST** be called on the synchronously dispatch queue stored in the `queue` property
 */
- (BOOL)closeInternal
{
    if (![self isOpen]) {
        return NO;
    }

    os_log_info(CDTOSLog, "Close %{public}@", _path);
    [[NSNotificationCenter defaultCenter] postNotificationName:TD_DatabaseWillCloseNotification
                                                        object:self];
    for (TD_View* view in _views.allValues) [view databaseClosing];

    _views = nil;
    for (TDReplicator* repl in _activeReplicators.copy) [repl databaseClosing];

    _activeReplicators = nil;

    [_fmdbQueue close];
    _fmdbQueue = nil;

    _keyProviderToOpenDB = nil;

    _attachments = nil;

    self.open = NO;
    _transactionLevel = 0;
    return YES;
}

- (BOOL)deleteDatabase:(NSError **)outError
{
    __block BOOL result =  NO;
    __block NSError *strongError = nil;
    dispatch_sync(self.queue, ^{
        NSError *innerError = nil;
        result = [self deleteDatabaseInternal:&innerError];
        if (innerError) strongError = innerError;
    });
    if (outError != nil) *outError = strongError;
    return result;
}

/**
 * Deletes the database, this **MUST** only be called synchronously on the dispatch queue stored in the `queue` property.
 */
- (BOOL)deleteDatabaseInternal:(NSError **)outError
{
    [[NSNotificationCenter defaultCenter] postNotificationName:TD_DatabaseWillBeDeletedNotification
                                                        object:self];

    if (self.open && ![self closeInternal]) {
        os_log_error(CDTOSLog, "Database at path %{public}@ could not be closed", _path);

        return NO;
    }

    return [[self class] deleteClosedDatabaseAtPath:_path error:outError];

}

+ (BOOL)deleteClosedDatabaseAtPath:(NSString *)path error:(NSError **)outError
{
    os_log_info(CDTOSLog, "Deleting %{public}@", path);
    
    BOOL success = YES;

    if ([TD_Database existsDatabaseAtPath:path]) {
        NSString *attachmentsPath = [TD_Database attachmentStorePathWithDatabasePath:path];

        // Delete the database file, and the associated temp files if they are present.
        success =
            (removeItemIfExists(path, outError) && removeItemIfExists(attachmentsPath, outError) &&
             removeItemIfExists([path stringByAppendingString:@"-wal"], outError) &&
             removeItemIfExists([path stringByAppendingString:@"-shm"], outError));
    }

    return success;
}

- (void)dealloc
{
    os_log_debug(CDTOSLog, "-dealloc TD_Database %{public}@", self);
    if (self.isOpen) {
        os_log_debug(CDTOSLog, "dealloced without being closed first! %{public}@", self);
        [self close];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@synthesize path = _path, name = _name, readOnly = _readOnly;

- (TDStatus)inTransaction:(TDStatus (^)(FMDatabase*))block
{
    __block TDStatus status;

    [_fmdbQueue inTransaction:^(FMDatabase* db, BOOL* rollback) {
        @try {
            status = block(db);
        }
        @catch (NSException* x)
        {
            os_log_debug(CDTOSLog, "Exception raised during -inTransaction: %{public}@", x);
            status = kTDStatusException;
        }
        @finally { *rollback = TDStatusIsError(status); }
    }];
    return status;
}

- (NSString*)privateUUID
{
    __block NSString* result;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        result = [db stringForQuery:@"SELECT value FROM info WHERE key='privateUUID'"];
    }];
    return result;
}

- (NSString*)publicUUID
{
    __block NSString* result;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        result = [db stringForQuery:@"SELECT value FROM info WHERE key='publicUUID'"];
    }];
    return result;
}

#pragma mark - GETTING DOCUMENTS:

- (NSUInteger)documentCount
{
    __block NSUInteger result = NSNotFound;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        FMResultSet* r = [db executeQuery:@"SELECT COUNT(DISTINCT doc_id) FROM revs "
                                           "WHERE current=1 AND deleted=0"];
        if ([r next]) {
            result = [r intForColumnIndex:0];
        }
        [r close];
    }];
    return result;
}

- (SequenceNumber)lastSequence
{
    __block SequenceNumber result = 0;
    [_fmdbQueue inDatabase:^(FMDatabase* db) { result = [self lastSequenceInDatabase:db]; }];
    return result;
}

/** Always call from within FMDatabaseQueue block */
- (SequenceNumber)lastSequenceInDatabase:(FMDatabase*)db
{
    return [db longLongForQuery:@"SELECT MAX(sequence) FROM revs"];
}

/** Inserts the _id, _rev and _attachments properties into the JSON data and stores it in rev.
    Rev must already have its revID and sequence properties set. */
- (NSDictionary*)extraPropertiesForRevision:(TD_Revision*)rev
                                    options:(TDContentOptions)options
                                 inDatabase:(FMDatabase*)db
{
    NSString* docID = rev.docID;
    NSString* revID = rev.revID;
    SequenceNumber sequence = rev.sequence;
    Assert(revID);
    Assert(sequence > 0);

    // Get attachment metadata, and optionally the contents:
    NSDictionary* attachmentsDict =
        [self getAttachmentDictForSequence:sequence options:options inDatabase:db];

    // Get more optional stuff to put in the properties:
    // OPT: This probably ends up making redundant SQL queries if multiple options are enabled.
    id localSeq = nil, revs = nil, revsInfo = nil, conflicts = nil;
    if (options & kTDIncludeLocalSeq) localSeq = @(sequence);

    if (options & kTDIncludeRevs) {
        revs = [self getRevisionHistoryDict:rev inDatabase:db];
    }

    if (options & kTDIncludeRevsInfo) {
        revsInfo = [[self getRevisionHistory:rev] my_map:^id(TD_Revision* rev) {
            NSString* status = @"available";
            if (rev.deleted)
                status = @"deleted";
            else if (rev.missing)
                status = @"missing";
            return $dict({ @"rev", [rev revID] }, { @"status", status });
        }];
    }

    if (options & kTDIncludeConflicts) {
        TD_RevisionList* revs =
            [self getAllRevisionsOfDocumentID:docID onlyCurrent:YES excludeDeleted:YES database:db];
        if (revs.count > 1) {
            conflicts = [revs.allRevisions my_map:^(id aRev) {
                return ($equal(aRev, rev) || [(TD_Revision*)aRev deleted]) ? nil : [aRev revID];
            }];
        }
    }

    return $dict({ @"_id", docID }, { @"_rev", revID },
                 { @"_deleted", (rev.deleted ? $true : nil) }, { @"_attachments", attachmentsDict },
                 { @"_local_seq", localSeq }, { @"_revisions", revs }, { @"_revs_info", revsInfo },
                 { @"_conflicts", conflicts });
}

/** Inserts the _id, _rev and _attachments properties into the JSON data and stores it in rev.
 Rev must already have its revID and sequence properties set. */
/** Only call from within a queued transaction **/
- (void)expandStoredJSON:(NSData*)json
            intoRevision:(TD_Revision*)rev
                 options:(TDContentOptions)options
              inDatabase:(FMDatabase*)db
{
    NSDictionary* extra = [self extraPropertiesForRevision:rev options:options inDatabase:db];
    if (json.length > 0) {
        rev.asJSON = [TDJSON appendDictionary:extra toJSONDictionaryData:json];
    } else {
        rev.properties = extra;
        if (json == nil) rev.missing = true;
    }
}

- (NSDictionary*)documentPropertiesFromJSON:(NSData*)json
                                      docID:(NSString*)docID
                                      revID:(NSString*)revID
                                    deleted:(BOOL)deleted
                                   sequence:(SequenceNumber)sequence
                                    options:(TDContentOptions)options
                                 inDatabase:(FMDatabase*)db
{
    TD_Revision* rev = [[TD_Revision alloc] initWithDocID:docID revID:revID deleted:deleted];
    rev.sequence = sequence;
    rev.missing = (json == nil);
    NSDictionary* extra = [self extraPropertiesForRevision:rev options:options inDatabase:db];
    if (json.length == 0 || (json.length == 2 && memcmp(json.bytes, "{}", 2) == 0))
        return extra;  // optimization, and workaround for issue #44
    NSMutableDictionary* docProperties =
        [TDJSON JSONObjectWithData:json options:TDJSONReadingMutableContainers error:NULL];
    if (!docProperties) {
        os_log_debug(CDTOSLog, "Unparseable JSON for doc=%{public}@, rev=%{public}@: %{public}@", docID, revID,
                     [json my_UTF8ToString]);
        return extra;
    }
    [docProperties addEntriesFromDictionary:extra];
    return docProperties;
}

/** public method, don't call when in FMDatabaseQueue block, or it will deadlock */
- (TD_Revision*)getDocumentWithID:(NSString*)docID
                       revisionID:(NSString*)revID
                          options:(TDContentOptions)options
                           status:(TDStatus*)outStatus
{
    __block TD_Revision* result;
    __weak TD_Database* weakSelf = self;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        TD_Database* strongSelf = weakSelf;
        result = [strongSelf getDocumentWithID:docID
                                    revisionID:revID
                                       options:options
                                        status:outStatus
                                      database:db];
    }];
    return result;
}

/** Only call from within a queued transaction **/
- (TD_Revision*)getDocumentWithID:(NSString*)docID
                       revisionID:(NSString*)revID
                          options:(TDContentOptions)options
                           status:(TDStatus*)outStatus
                         database:(FMDatabase*)db
{
    TD_Revision* result = nil;
    NSMutableString* sql = [NSMutableString stringWithString:@"SELECT revid, deleted, sequence"];
    if (!(options & kTDNoBody)) [sql appendString:@", json"];
    if (revID)
        [sql appendString:@" FROM revs, docs "
                           "WHERE docs.docid=? AND revs.doc_id=docs.doc_id AND revid=? AND json "
                           "notnull LIMIT 1"];
    else
        [sql appendString:
                 @" FROM revs, docs "
                  "WHERE docs.docid=? AND revs.doc_id=docs.doc_id and current=1 and deleted=0 "
                  "ORDER BY revid DESC LIMIT 1"];
    FMResultSet* r = [db executeQuery:sql, docID, revID];
    if (!r) {
        *outStatus = kTDStatusDBError;
    } else if (![r next]) {
        if (!revID && [self getDocNumericID:docID database:db] > 0)
            *outStatus = kTDStatusDeleted;
        else
            *outStatus = kTDStatusNotFound;
    } else {
        if (!revID) revID = [r stringForColumnIndex:0];
        BOOL deleted = [r boolForColumnIndex:1];
        result = [[TD_Revision alloc] initWithDocID:docID revID:revID deleted:deleted];
        result.sequence = [r longLongIntForColumnIndex:2];

        if (options != kTDNoBody) {
            NSData* json = nil;
            if (!(options & kTDNoBody)) json = [r dataNoCopyForColumnIndex:3];
            [self expandStoredJSON:json intoRevision:result options:options inDatabase:db];
        }
        *outStatus = kTDStatusOK;
    }
    [r close];
    return result;
}

/** public method, don't call when in FMDatabaseQueue block, or it will deadlock */
- (TD_Revision*)getDocumentWithID:(NSString*)docID revisionID:(NSString*)revID
{
    __block TD_Revision* result;
    __weak TD_Database* weakSelf = self;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        TD_Database* strongSelf = weakSelf;
        result = [strongSelf getDocumentWithID:docID revisionID:revID database:db];
    }];
    return result;
}

/** Only call from within a queued transaction **/
- (TD_Revision*)getDocumentWithID:(NSString*)docID
                       revisionID:(NSString*)revID
                         database:(FMDatabase*)db
{
    TDStatus status;
    return [self getDocumentWithID:docID revisionID:revID options:0 status:&status database:db];
}

/** Only call from within a queued transaction **/
- (BOOL)existsDocumentWithID:(NSString*)docID revisionID:(NSString*)revID database:(FMDatabase*)db
{
    TDStatus status;

    TD_Revision* rev = [self getDocumentWithID:docID
                                    revisionID:revID
                                       options:kTDNoBody
                                        status:&status
                                      database:db];

    if (status == kTDStatusDeleted) {
        return YES;  // The doc is now a tombstone, but it does mean it exits in the tree.
    } else {
        return rev != nil;
    }
}

/** Do not call from fmdbqueue */
- (TDStatus)loadRevisionBody:(TD_Revision*)rev options:(TDContentOptions)options
{
    __block TDStatus result = kTDStatusDBError;

    if ([self isOpen]) {
        __weak TD_Database* weakSelf = self;
        [_fmdbQueue inDatabase:^(FMDatabase* db) {
          __strong TD_Database* strongSelf = weakSelf;
          if (strongSelf) {
              result = [strongSelf loadRevisionBody:rev options:options database:db];
          }
        }];
    } else {
        os_log_debug(CDTOSLog, "Database is not open");
    }

    return result;
}

/** Only call from within a queued transaction **/
- (TDStatus)loadRevisionBody:(TD_Revision*)rev
                     options:(TDContentOptions)options
                    database:(FMDatabase*)db
{
    if (rev.body && options == 0) return kTDStatusOK;
    Assert(rev.docID && rev.revID);
    FMResultSet* r =
        [db executeQuery:@"SELECT sequence, json FROM revs, docs "
                          "WHERE revid=? AND docs.docid=? AND revs.doc_id=docs.doc_id LIMIT 1",
                         rev.revID, rev.docID];
    if (!r) return kTDStatusDBError;
    TDStatus status = kTDStatusNotFound;
    if ([r next]) {
        // Found the rev. But the JSON still might be null if the database has been compacted.
        status = kTDStatusOK;
        rev.sequence = [r longLongIntForColumnIndex:0];
        [self expandStoredJSON:[r dataNoCopyForColumnIndex:1]
                  intoRevision:rev
                       options:options
                    inDatabase:db];
    }
    [r close];
    return status;
}

/** Only call from within a queued transaction **/
- (SInt64)getDocNumericID:(NSString*)docID database:(FMDatabase*)db
{
    Assert(docID);
    return [db longLongForQuery:@"SELECT doc_id FROM docs WHERE docid=?", docID];
}

/** Only call from within a queued transaction **/
- (SequenceNumber)getSequenceOfDocument:(SInt64)docNumericID
                               revision:(NSString*)revID
                            onlyCurrent:(BOOL)onlyCurrent
                               database:(FMDatabase*)db
{
    NSString* sql = $sprintf(@"SELECT sequence FROM revs WHERE doc_id=? AND revid=? %@ LIMIT 1",
                             (onlyCurrent ? @"AND current=1" : @""));
    return [db longLongForQuery:sql, @(docNumericID), revID];
}

#pragma mark - HISTORY:

/** Only call from within a queued transaction
 This method was created seperately with the numericID specified in
 order to be used within TD_Database+Insertion -forceInsert:revisionHistory:source
 **/
- (nullable TD_RevisionList*)getAllRevisionsOfDocumentID:(NSString*)docID
                                               numericID:(SInt64)docNumericID
                                             onlyCurrent:(BOOL)onlyCurrent
                                          excludeDeleted:(BOOL)excludeDeleted
                                                database:(FMDatabase*)db
{
    NSString* sql = @"SELECT sequence, revid, deleted FROM revs WHERE doc_id=? ";

    if (onlyCurrent) {
        sql = [sql stringByAppendingString:@"AND current = 1 "];
    }

    if (excludeDeleted) {
        sql = [sql stringByAppendingString:@"AND deleted = 0 "];
    }

    sql = [sql stringByAppendingString:@"ORDER BY sequence DESC"];

    FMResultSet* r = [db executeQuery:sql, @(docNumericID)];
    if (!r) {
        return nil;
    }

    TD_RevisionList* revs = [[TD_RevisionList alloc] init];
    while ([r next]) {
        TD_Revision* rev = [[TD_Revision alloc] initWithDocID:docID
                                                        revID:[r stringForColumnIndex:1]
                                                      deleted:[r boolForColumnIndex:2]];
        rev.sequence = [r longLongIntForColumnIndex:0];
        [revs addRev:rev];
    }
    [r close];
    return revs;
}

- (TD_RevisionList*)getAllRevisionsOfDocumentID:(NSString*)docID
                                    onlyCurrent:(BOOL)onlyCurrent
                                 excludeDeleted:(BOOL)excludeDeleted
{
    __block TD_RevisionList* result;
    __weak TD_Database* weakSelf = self;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        TD_Database* strongSelf = weakSelf;
        result = [strongSelf getAllRevisionsOfDocumentID:docID
                                             onlyCurrent:onlyCurrent
                                          excludeDeleted:excludeDeleted
                                                database:db];
    }];
    return result;
}

/** Only call from within a queued transaction **/
- (TD_RevisionList*)getAllRevisionsOfDocumentID:(NSString*)docID
                                    onlyCurrent:(BOOL)onlyCurrent
                                 excludeDeleted:(BOOL)excludeDeleted
                                       database:(FMDatabase*)db
{
    SInt64 docNumericID = [self getDocNumericID:docID database:db];
    if (docNumericID < 0) {
        return nil;
    } else if (docNumericID == 0) {
        return [[TD_RevisionList alloc] init];  // no such document
    } else {
        return [self getAllRevisionsOfDocumentID:docID
                                       numericID:docNumericID
                                     onlyCurrent:onlyCurrent
                                  excludeDeleted:excludeDeleted
                                        database:db];
    }
}

static NSArray* revIDsFromResultSet(FMResultSet* r)
{
    if (!r) return nil;
    NSMutableArray* revIDs = $marray();
    while ([r next]) [revIDs addObject:[r stringForColumnIndex:0]];
    [r close];
    return revIDs;
}

/** Only call from within a queued transaction **/
- (NSArray*)getPossibleAncestorRevisionIDs:(TD_Revision*)rev limit:(unsigned)limit
{
    __block NSArray* result;
    __weak TD_Database* weakSelf = self;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        TD_Database* strongSelf = weakSelf;
        result = [strongSelf getPossibleAncestorRevisionIDs:rev limit:limit database:db];
    }];
    return result;
}

/** Only call from within a queued transaction **/
- (NSArray*)getPossibleAncestorRevisionIDs:(TD_Revision*)rev
                                     limit:(unsigned)limit
                                  database:(FMDatabase*)db
{
    int generation = rev.generation;
    if (generation <= 1) return nil;
    SInt64 docNumericID = [self getDocNumericID:rev.docID database:db];
    if (docNumericID <= 0) return nil;
    int sqlLimit = limit > 0 ? (int)limit : -1;  // SQL uses -1, not 0, to denote 'no limit'
    FMResultSet* r = [db executeQuery:@"SELECT revid FROM revs WHERE doc_id=? and revid < ?"
                                       " and deleted=0 and json not null"
                                       " ORDER BY sequence DESC LIMIT ?",
                                      @(docNumericID), $sprintf(@"%d-", generation), @(sqlLimit)];
    return revIDsFromResultSet(r);
}

/** Only call from within a queued transaction **/
- (NSString*)findCommonAncestorOf:(TD_Revision*)rev
                       withRevIDs:(NSArray*)revIDs
                         database:(FMDatabase*)db
{
    if (revIDs.count == 0) return nil;
    SInt64 docNumericID = [self getDocNumericID:rev.docID database:db];
    if (docNumericID <= 0) return nil;
    NSString* sql = $sprintf(@"SELECT revid FROM revs "
                              "WHERE doc_id=? and revid in (%@) and revid <= ? "
                              "ORDER BY revid DESC LIMIT 1",
                             [TD_Database joinQuotedStrings:revIDs]);
    return [db stringForQuery:sql, @(docNumericID), rev.revID];
}

- (NSArray*)getRevisionHistory:(TD_Revision*)rev
{
    __block NSArray* result;
    __weak TD_Database* weakSelf = self;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        TD_Database* strongSelf = weakSelf;
        result = [strongSelf getRevisionHistory:rev database:db];
    }];
    return result;
}

/** Only call from within a queued transaction **/
- (NSArray*)getRevisionHistory:(TD_Revision*)rev database:(FMDatabase*)db
{
    NSString* docID = rev.docID;
    NSString* revID = rev.revID;
    Assert(revID && docID);

    SInt64 docNumericID = [self getDocNumericID:docID database:db];
    if (docNumericID < 0)
        return nil;
    else if (docNumericID == 0)
        return @[];

    FMResultSet* r = [db executeQuery:@"SELECT sequence, parent, revid, deleted, json isnull "
                                       "FROM revs WHERE doc_id=? ORDER BY sequence DESC",
                                      @(docNumericID)];
    if (!r) return nil;
    SequenceNumber lastSequence = 0;
    NSMutableArray* history = $marray();
    while ([r next]) {
        SequenceNumber sequence = [r longLongIntForColumnIndex:0];
        BOOL matches;
        if (lastSequence == 0)
            matches = ($equal(revID, [r stringForColumnIndex:2]));
        else
            matches = (sequence == lastSequence);
        if (matches) {
            NSString* revID = [r stringForColumnIndex:2];
            BOOL deleted = [r boolForColumnIndex:3];
            TD_Revision* rev =
                [[TD_Revision alloc] initWithDocID:docID revID:revID deleted:deleted];
            rev.sequence = sequence;
            rev.missing = [r boolForColumnIndex:4];
            [history addObject:rev];
            lastSequence = [r longLongIntForColumnIndex:1];
            if (lastSequence == 0) break;
        }
    }
    [r close];
    return history;
}

// static designation was removed in order to use this function outside of this file
// however, it was not declared in the header because we don't really want to expose
// it to users. although it's not needed, specifically state 'extern' here
// in order to be clear on intent.
// Adam Cox, Cloudant, Inc. (2014)
extern NSDictionary* makeRevisionHistoryDict(NSArray* history)
{
    if (!history) return nil;

    // Try to extract descending numeric prefixes:
    NSMutableArray* suffixes = $marray();
    id start = nil;
    int lastRevNo = -1;
    for (TD_Revision* rev in history) {
        int revNo;
        NSString* suffix;
        if ([TD_Revision parseRevID:rev.revID intoGeneration:&revNo andSuffix:&suffix]) {
            if (!start)
                start = @(revNo);
            else if (revNo != lastRevNo - 1) {
                start = nil;
                break;
            }
            lastRevNo = revNo;
            [suffixes addObject:suffix];
        } else {
            start = nil;
            break;
        }
    }

    NSArray* revIDs = start ? suffixes : [history my_map:^(id rev) { return [rev revID]; }];
    return $dict({ @"ids", revIDs }, { @"start", start });
}

- (NSDictionary*)getRevisionHistoryDict:(TD_Revision*)rev inDatabase:(FMDatabase*)db
{
    return makeRevisionHistoryDict([self getRevisionHistory:rev database:db]);
}

/** Only call from within a queued transaction **/
- (NSString*)getParentRevID:(TD_Revision*)rev database:(FMDatabase*)db
{
    Assert(rev.sequence > 0);
    return [db stringForQuery:@"SELECT parent.revid FROM revs, revs as parent"
                               " WHERE revs.sequence=? and parent.sequence=revs.parent",
                              @(rev.sequence)];
}

/** Returns the rev ID of the 'winning' revision of this document, and whether it's deleted. */
/** Only call from within a queued transaction **/
- (nullable NSString*)winningRevIDOfDocNumericID:(SInt64)docNumericID
                                       isDeleted:(BOOL*)outIsDeleted
                                        database:(FMDatabase*)db
{
    Assert(docNumericID > 0);
    FMResultSet* r = [db executeQuery:@"SELECT revid, deleted FROM revs"
                                       " WHERE doc_id=? and current=1"
                                       " ORDER BY deleted asc, revid desc LIMIT 1",
                                      @(docNumericID)];
    NSString* revID = nil;
    if ([r next]) {
        revID = [r stringForColumnIndex:0];
        *outIsDeleted = [r boolForColumnIndex:1];
    } else {
        *outIsDeleted = NO;
    }
    [r close];
    return revID;
}

const TDChangesOptions kDefaultTDChangesOptions = {UINT_MAX, 0, NO, NO, YES};

- (TD_RevisionList*)changesSinceSequence:(SequenceNumber)lastSequence
                                 options:(const TDChangesOptions*)options
                                  filter:(TD_FilterBlock)filter
                                  params:(NSDictionary*)filterParams
{
    __block TD_RevisionList* result;
    __weak TD_Database* weakSelf = self;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        TD_Database* strongSelf = weakSelf;
        result = [strongSelf changesSinceSequence:lastSequence
                                          options:options
                                           filter:filter
                                           params:filterParams
                                         database:db];
    }];
    return result;
}

/** Only call from within a queued transaction **/
- (TD_RevisionList*)changesSinceSequence:(SequenceNumber)lastSequence
                                 options:(const TDChangesOptions*)options
                                  filter:(TD_FilterBlock)filter
                                  params:(NSDictionary*)filterParams
                                database:(FMDatabase*)db
{
    // http://wiki.apache.org/couchdb/HTTP_database_API#Changes
    if (!options) options = &kDefaultTDChangesOptions;
    BOOL includeDocs = options->includeDocs || (filter != NULL);

    NSString* sql =
        $sprintf(@"SELECT sequence, revs.doc_id, docid, revid, deleted %@ FROM revs, docs "
                  "WHERE sequence > ? AND current=1 "
                  "AND revs.doc_id = docs.doc_id "
                  "ORDER BY revs.doc_id, revid DESC",
                 (includeDocs ? @", json" : @""));
    FMResultSet* r = [db executeQuery:sql, @(lastSequence)];
    if (!r) return nil;
    TD_RevisionList* changes = [[TD_RevisionList alloc] init];
    int64_t lastDocID = 0;
    while ([r next]) {
        @autoreleasepool
        {
            if (!options->includeConflicts) {
                // Only count the first rev for a given doc (the rest will be losing conflicts):
                int64_t docNumericID = [r longLongIntForColumnIndex:1];
                if (docNumericID == lastDocID) continue;
                lastDocID = docNumericID;
            }

            TD_Revision* rev = [[TD_Revision alloc] initWithDocID:[r stringForColumnIndex:2]
                                                            revID:[r stringForColumnIndex:3]
                                                          deleted:[r boolForColumnIndex:4]];
            rev.sequence = [r longLongIntForColumnIndex:0];
            if (includeDocs) {
                [self expandStoredJSON:[r dataNoCopyForColumnIndex:5]
                          intoRevision:rev
                               options:options->contentOptions
                            inDatabase:db];
            }
            if (!filter || filter(rev, filterParams)) [changes addRev:rev];
        }
    }
    [r close];

    if (options->sortBySequence) {
        [changes sortBySequence];
        [changes limit:options->limit];
    }
    return changes;
}

#pragma mark - VIEWS:

- (TD_View*)registerView:(TD_View*)view
{
    if (!view) return nil;
    if (!_views) _views = [[NSMutableDictionary alloc] init];
    _views[view.name] = view;
    return view;
}

- (TD_View*)viewNamed:(NSString*)name
{
    TD_View* view = _views[name];
    if (view) return view;
    return [self registerView:[[TD_View alloc] initWithDatabase:self name:name]];
}

- (TD_View*)existingViewNamed:(NSString*)name
{
    TD_View* view = _views[name];
    if (view) return view;
    view = [[TD_View alloc] initWithDatabase:self name:name];
    if (!view.viewID) return nil;
    return [self registerView:view];
}

- (NSArray*)allViews
{
    __block NSMutableArray* views;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        FMResultSet* r = [db executeQuery:@"SELECT name FROM views"];
        if (!r) {
            return;
        }
        views = $marray();
        while ([r next]) [views addObject:[self viewNamed:[r stringForColumnIndex:0]]];
        [r close];
    }];
    return views;
}

- (TDStatus)deleteViewNamed:(NSString*)name
{
    __block TDStatus result;
    [_fmdbQueue inDatabase:^(FMDatabase* db) {
        if (![db executeUpdate:@"DELETE FROM views WHERE name=?", name]) {
            result = kTDStatusDBError;
            return;
        }
        [self->_views removeObjectForKey:name];
        result = (db.changes ? kTDStatusOK : kTDStatusNotFound);
    }];
    return result;
}

- (TD_View*)compileViewNamed:(NSString*)tdViewName status:(TDStatus*)outStatus
{
    TD_View* view = [self existingViewNamed:tdViewName];
    if (view && view.mapBlock) return view;

    // No TouchDB view is defined, or it hasn't had a map block assigned;
    // see if there's a CouchDB view definition we can compile:
    NSArray* path = [tdViewName componentsSeparatedByString:@"/"];
    if (path.count != 2) {
        *outStatus = kTDStatusNotFound;
        return nil;
    }
    TD_Revision* rev =
        [self getDocumentWithID:[@"_design/" stringByAppendingString:path[0]] revisionID:nil];
    if (!rev) {
        *outStatus = kTDStatusNotFound;
        return nil;
    }
    NSDictionary* views = $castIf(NSDictionary, rev[@"views"]);
    NSDictionary* viewProps = $castIf(NSDictionary, views[path[1]]);
    if (!viewProps) {
        *outStatus = kTDStatusNotFound;
        return nil;
    }

    // If there is a CouchDB view, see if it can be compiled from source:
    view = [self viewNamed:tdViewName];
    if (![view compileFromProperties:viewProps]) {
        *outStatus = kTDStatusCallbackError;
        return nil;
    }
    return view;
}

// FIX: This has a lot of code in common with -[TD_View queryWithOptions:status:]. Unify the two!
- (NSDictionary*)getDocsWithIDs:(NSArray*)docIDs options:(const TDQueryOptions*)options
{
    if (!options) options = &kDefaultTDQueryOptions;

    // Generate the SELECT statement, based on the options:
    NSMutableString* sql = [@"SELECT revs.doc_id, docid, revid" mutableCopy];
    if (options->includeDocs) [sql appendString:@", json, sequence"];
    if (options->includeDeletedDocs) [sql appendString:@", deleted"];
    [sql appendString:@" FROM revs, docs WHERE"];
    if (docIDs) [sql appendFormat:@" docid IN (%@) AND", [TD_Database joinQuotedStrings:docIDs]];
    [sql appendString:@" docs.doc_id = revs.doc_id AND current=1"];
    if (!options->includeDeletedDocs) [sql appendString:@" AND deleted=0"];

    NSMutableArray* args = $marray();
    id minKey = options->startKey, maxKey = options->endKey;
    BOOL inclusiveMin = YES, inclusiveMax = options->inclusiveEnd;
    if (options->descending) {
        minKey = maxKey;
        maxKey = options->startKey;
        inclusiveMin = inclusiveMax;
        inclusiveMax = YES;
    }
    if (minKey) {
        Assert([minKey isKindOfClass:[NSString class]]);
        [sql appendString:(inclusiveMin ? @" AND docid >= ?" : @" AND docid > ?")];
        [args addObject:minKey];
    }
    if (maxKey) {
        Assert([maxKey isKindOfClass:[NSString class]]);
        [sql appendString:(inclusiveMax ? @" AND docid <= ?" : @" AND docid < ?")];
        [args addObject:maxKey];
    }

    [sql appendFormat:@" ORDER BY docid %@, %@ revid DESC LIMIT ? OFFSET ?",
                      (options->descending ? @"DESC" : @"ASC"),
                      (options->includeDeletedDocs ? @"deleted ASC," : @"")];
    [args addObject:@(options->limit)];
    [args addObject:@(options->skip)];

    __block SequenceNumber update_seq = 0;
    __block NSMutableArray* rows = $marray();

    [_fmdbQueue inTransaction:^(FMDatabase* db, BOOL* rollback) {
        if (options->updateSeq)
            update_seq = self.lastSequence;  // TODO: needs to be atomic with the following SELECT

        // Now run the database query:
        FMResultSet* r = [db executeQuery:sql withArgumentsInArray:args];
        if (!r) return;

        int64_t lastDocID = 0;
        NSMutableDictionary* docs = docIDs ? $mdict() : nil;
        while ([r next]) {
            @autoreleasepool
            {
                // Only count the first rev for a given doc (the rest will be losing conflicts):
                int64_t docNumericID = [r longLongIntForColumnIndex:0];
                if (docNumericID == lastDocID) continue;
                lastDocID = docNumericID;

                NSString* docID = [r stringForColumnIndex:1];
                NSString* revID = [r stringForColumnIndex:2];
                BOOL deleted = options->includeDeletedDocs && [r boolForColumn:@"deleted"];
                NSDictionary* docContents = nil;
                if (options->includeDocs) {
                    // Fill in the document contents:
                    NSData* json = [r dataNoCopyForColumnIndex:3];
                    SequenceNumber sequence = [r longLongIntForColumnIndex:4];
                    docContents = [self documentPropertiesFromJSON:json
                                                             docID:docID
                                                             revID:revID
                                                           deleted:deleted
                                                          sequence:sequence
                                                           options:options->content
                                                        inDatabase:db];
                    Assert(docContents);
                }
                NSDictionary* change = $dict(
                    { @"id", docID }, { @"key", docID },
                    { @"value", $dict({ @"rev", revID }, { @"deleted", (deleted ? $true : nil) }) },
                    { @"doc", docContents });
                if (docIDs)
                    [docs setObject:change forKey:docID];
                else
                    [rows addObject:change];
            }
        }
        [r close];

        // If given doc IDs, sort the output into that order, and add entries for missing docs:
        if (docIDs) {
            for (NSString* docID in docIDs) {
                NSDictionary* change = docs[docID];
                if (!change) {
                    NSString* revID = nil;
                    SInt64 docNumericID = [self getDocNumericID:docID database:db];
                    if (docNumericID > 0) {
                        BOOL deleted;
                        revID = [self winningRevIDOfDocNumericID:docNumericID
                                                       isDeleted:&deleted
                                                        database:db];
                    }
                    if (revID) {
                        change =
                            $dict({ @"id", docID }, { @"key", docID },
                                  { @"value", $dict({ @"rev", revID }, { @"deleted", $true }) });
                    } else {
                        change = $dict({ @"key", docID }, { @"error", @"not_found" });
                    }
                }
                [rows addObject:change];
            }
        }
    }];

    NSUInteger totalRows = rows.count;  //??? Is this true, or does it ignore limit/offset?
    return $dict({ @"rows", rows }, { @"total_rows", @(totalRows) },
                 { @"offset", @(options->skip) },
                 { @"update_seq", update_seq ? @(update_seq) : nil });
}

- (NSDictionary*)getAllDocs:(const TDQueryOptions*)options
{
    return [self getDocsWithIDs:nil options:options];
}

#pragma mark - QUEUE:

+ (FMDatabaseQueue *)queueForDatabaseAtPath:(NSString *)path readOnly:(BOOL)readOnly
{
#ifdef SQLITE_OPEN_FILEPROTECTION_COMPLETEUNLESSOPEN
    int flags = SQLITE_OPEN_FILEPROTECTION_COMPLETEUNLESSOPEN;
#else
    int flags = kNilOptions;
#endif
    if (readOnly) {
        flags |= SQLITE_OPEN_READONLY;
    } else {
        flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
    }
    os_log_debug(CDTOSLog, "Open %{public}@ (flags=%{public}X)", path, flags);

    FMDatabaseQueue *queue = [FMDatabaseQueue databaseQueueWithPath:path flags:flags];

    return queue;
}

- (void)clearPendingAttachments { _pendingAttachmentsByDigest = nil; }
@end
