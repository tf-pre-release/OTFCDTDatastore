//
//  TDBlobStore.m
//  TouchDB
//
//  Created by Jens Alfke on 12/10/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Modifications for this distribution by Cloudant, Inc., Copyright (c) 2014 Cloudant, Inc.
//  Copyright © 2018 IBM Corporation. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDBlobStore.h"
#import "TDBase64.h"
#import "TDMisc.h"
#import "CDTLogging.h"
#import <ctype.h>

#import "TDStatus.h"

#import "TD_Database+BlobFilenames.h"

#import "CDTBlobHandleFactory.h"
#import "Test.h"

#ifdef GNUSTEP
#define NSDataReadingMappedIfSafe NSMappedRead
#define NSDataWritingAtomic NSAtomicWrite
#endif

NSString *const CDTBlobStoreErrorDomain = @"CDTBlobStoreErrorDomain";

@interface TDBlobStore ()

@property (strong, nonatomic, readonly) NSString *path;
@property (strong, nonatomic, readonly) CDTBlobHandleFactory *blobHandleFactory;

@end

@implementation TDBlobStore

- (id)initWithPath:(NSString *)dir
    encryptionKeyProvider:(id<CDTEncryptionKeyProvider>)provider
                    error:(NSError **)outError;
{
    Assert(dir);
    Assert(provider, @"Key provider is mandatory. Supply a CDTNilEncryptionKeyProvider instead.");

    self = [super init];
    if (self) {
        BOOL success = YES;
        
        BOOL isDir;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                           withIntermediateDirectories:NO
                                                            attributes:nil
                                                                 error:outError]) {
                success = NO;
            }
        }
        
        if (success) {
            _path = [dir copy];
            _blobHandleFactory = [CDTBlobHandleFactory factoryWithEncryptionKeyProvider:provider];
        } else {
            self = nil;
        }
    }

    return self;
}

+ (TDBlobKey)keyForBlob:(NSData *)blob
{
    NSCParameterAssert(blob);

    TDBlobKey key;
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    CC_SHA1_Update(&ctx, blob.bytes, (CC_LONG)blob.length);
    CC_SHA1_Final(key.bytes, &ctx);

    return key;
}

+ (NSString *)blobPathWithStorePath:(NSString *)storePath blobFilename:(NSString *)blobFilename
{
    NSString *blobPath = nil;
    
    if (storePath && (storePath.length > 0) && blobFilename && (blobFilename.length > 0)) {
        blobPath = [storePath stringByAppendingPathComponent:blobFilename];
    }
    
    return blobPath;
}

- (id<CDTBlobReader>)blobForKey:(TDBlobKey)key withDatabase:(FMDatabase *)db
{
    NSString *filename = [TD_Database filenameForKey:key inBlobFilenamesTableInDatabase:db];
    NSString *blobPath = [TDBlobStore blobPathWithStorePath:_path blobFilename:filename];

    id<CDTBlobReader> reader = [_blobHandleFactory readerWithPath:blobPath];

    return reader;
}

- (BOOL)storeBlob:(NSData *)blob
      creatingKey:(TDBlobKey *)outKey
     withDatabase:(FMDatabase *)db
            error:(NSError *__autoreleasing *)outError
{
    // Search filename
    TDBlobKey thisKey = [TDBlobStore keyForBlob:blob];

    NSString *filename = [TD_Database filenameForKey:thisKey inBlobFilenamesTableInDatabase:db];
    if (filename) {
        os_log_debug(CDTOSLog, "Key already exists with filename %{public}@", filename);

        if (outKey) {
            *outKey = thisKey;
        }

        return YES;
    }

    // Create new if not exists
    filename = [TD_Database generateAndInsertRandomFilenameBasedOnKey:thisKey
                                     intoBlobFilenamesTableInDatabase:db];
    if (!filename) {
        os_log_error(CDTOSLog, "No filename generated");

        if (outError) {
            *outError = [TDBlobStore errorNoFilenameGenerated];
        }

        return NO;
    }

    // Get a writer
    NSString *blobPath = [TDBlobStore blobPathWithStorePath:_path blobFilename:filename];
    id<CDTBlobWriter> writer = [_blobHandleFactory writerWithPath:blobPath];

    // Save to disk
    NSError *thisError = nil;
    if (![writer writeEntireBlobWithData:blob error:&thisError]) {
        os_log_error(CDTOSLog, "Data not stored in %{public}@: %{public}@", blobPath, thisError);

        [TD_Database deleteRowForKey:thisKey inBlobFilenamesTableInDatabase:db];

        if (outError) {
            *outError = thisError;
        }

        return NO;
    }

    // Return
    if (outKey) {
        *outKey = thisKey;
    }

    return YES;
}

- (NSUInteger)countWithDatabase:(FMDatabase *)db
{
    NSUInteger n = [TD_Database countRowsInBlobFilenamesTableInDatabase:db];

    return n;
}

- (BOOL)deleteBlobsExceptWithKeys:(NSSet *)keysToKeep withDatabase:(FMDatabase *)db
{
    BOOL success = YES;

    NSMutableSet *filesToKeep = [NSMutableSet setWithCapacity:keysToKeep.count];

    // Delete attachments from database
    NSArray *allRows = [TD_Database rowsInBlobFilenamesTableInDatabase:db];

    for (TD_DatabaseBlobFilenameRow *oneRow in allRows) {
        // Check if key is an exception
        NSData *curKeyData =
            [NSData dataWithBytes:oneRow.key.bytes length:sizeof(oneRow.key.bytes)];
        if ([keysToKeep containsObject:curKeyData]) {
            // Do not delete blob. It is an exception.
            [filesToKeep addObject:oneRow.blobFilename];

            continue;
        }

        // Remove from db
        if (![TD_Database deleteRowForKey:oneRow.key inBlobFilenamesTableInDatabase:db]) {
            os_log_error(CDTOSLog, "%{public}@: Failed to delete '%{public}@' from db", self, oneRow.blobFilename);

            success = NO;

            // Do not try to delete it later, it will not be deleted from db
            [filesToKeep addObject:oneRow.blobFilename];
        }
    }

    // Delete attachments from disk. In fact, this method will delete all the files in the folder
    // but the exception
    // NOTICE: If for some reason one of the files is not deleted and later we generate the same
    // filename for another attachment, the content of this file will be overwritten with the new
    // data
    [TDBlobStore deleteFilesNotInSet:filesToKeep fromPath:_path];

    // Return
    return success;
}

+ (void)deleteFilesNotInSet:(NSSet*)filesToKeep fromPath:(NSString *)path
{
    NSFileManager* defaultManager = [NSFileManager defaultManager];

    // Read directory
    NSError* thisError = nil;
    NSArray* currentFiles = [defaultManager contentsOfDirectoryAtPath:path error:&thisError];
    if (!currentFiles) {
        os_log_error(CDTOSLog, "Can not read dir %{public}@: %{public}@", path, thisError);
        return;
    }

    // Delete all files but exceptions
    for (NSString* filename in currentFiles) {
        if ([filesToKeep containsObject:filename]) {
            // Do not delete file. It is an exception.
            continue;
        }

        NSString* filePath = [TDBlobStore blobPathWithStorePath:path blobFilename:filename];

        if (![defaultManager removeItemAtPath:filePath error:&thisError]) {
            os_log_error(CDTOSLog, "%{public}@: Failed to delete '%{public}@' not related to an attachment: %{public}@", self,
                         filename, thisError);
        }
    }
}

- (NSString*)tempDir
{
    if (!_tempDir) {
// Find a temporary directory suitable for files that will be moved into the store:
#ifdef GNUSTEP
        _tempDir = [NSTemporaryDirectory() copy];
#else
        NSError* error;
        NSURL *tempDirURL = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];

        _tempDir = [tempDirURL.path copy];
        os_log_info(CDTOSLog, "TDBlobStore %{public}@ created tempDir %{public}@", _path, _tempDir);
        if (!_tempDir)
            os_log_debug(CDTOSLog, "TDBlobStore: Unable to create temp dir: %{public}@", error);
#endif
    }
    return _tempDir;
}

+ (NSError *)errorNoFilenameGenerated
{
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey :
            NSLocalizedString(@"No filename generated", @"No filename generated")
    };

    return [NSError errorWithDomain:CDTBlobStoreErrorDomain
                               code:CDTBlobStoreErrorNoFilenameGenerated
                           userInfo:userInfo];
}

@end

@implementation TDBlobStoreWriter

@synthesize length = _length, blobKey = _blobKey;

- (id)initWithStore:(TDBlobStore*)store
{
    self = [super init];
    if (self) {
        _store = store;
        CC_SHA1_Init(&_shaCtx);
        CC_SHA256_Init(&_sha256Ctx);

        // Open a temporary file in the store's temporary directory:
        NSString* filename = [TDCreateUUID() stringByAppendingPathExtension:@"blobtmp"];
        _tempPath = [[_store.tempDir stringByAppendingPathComponent:filename] copy];
        if (!_tempPath) {
            return nil;
        }
        
        _blobWriter = [store.blobHandleFactory writerWithPath:_tempPath];
        if (![_blobWriter openForWriting]) {
            return nil;
        }
    }
    return self;
}

- (void)appendData:(NSData*)data
{
    [_blobWriter appendData:data];
    NSUInteger dataLen = data.length;
    _length += dataLen;
    CC_SHA1_Update(&_shaCtx, data.bytes, (CC_LONG)dataLen);
    CC_SHA256_Update(&_sha256Ctx, data.bytes, (CC_LONG)dataLen);
}

- (void)closeFile
{
    [_blobWriter close];
    _blobWriter = nil;
}

- (void)finish
{
    Assert(_blobWriter, @"Already finished");
    [self closeFile];
    CC_SHA1_Final(_blobKey.bytes, &_shaCtx);
    CC_SHA256_Final(_blobKey.bytes, &_sha256Ctx);
}

- (NSString*)MD5DigestString
{
    return
        [@"md5-" stringByAppendingString:[TDBase64 encode:&_MD5Digest length:sizeof(_MD5Digest)]];
}

- (NSString*)SHA1DigestString
{
    return [@"sha1-" stringByAppendingString:[TDBase64 encode:&_blobKey length:sizeof(_blobKey)]];
}

- (BOOL)installWithDatabase:(FMDatabase *)db
{
    if (!_tempPath) {
        return YES;  // already installed
    }

    Assert(!_blobWriter, @"Not finished");

    // Search filename
    NSString *filename = [self filenameInDatabase:db];
    if (filename) {
        os_log_debug(CDTOSLog, "Key already exists with filename %{public}@", filename);

        [self cancel];

        return YES;
    }

    // Create if not exists
    filename = [self generateAndInsertRandomFilenameInDatabase:db];
    if (!filename) {
        os_log_error(CDTOSLog, "No filename generated");

        [self cancel];

        return NO;
    }

    // Check there is not a file in the destination path with the same filename
    NSString *dstPath = [TDBlobStore blobPathWithStorePath:_store.path blobFilename:filename];

    NSFileManager *defaultManager = [NSFileManager defaultManager];

    NSError *error = nil;
    if ([defaultManager fileExistsAtPath:dstPath]) {
        os_log_debug(CDTOSLog, "File exists at path %{public}@. Delete before moving", dstPath);

        // If this ever happens, we can safely assume that on a previous moment
        // 'TDBlobStore:storeBlob:creatingKey:withDatabase:error:' (or
        // 'TDBlobStoreWriter:installWithDatabase:') was executed in a block that was finally
        // rollback. Therefore, the file in the destination path is not linked to any attachment
        // and we can remove it.
        if (![defaultManager removeItemAtPath:dstPath error:&error]) {
            os_log_error(CDTOSLog, "Not deleted pre-existing file at path %{public}@: %{public}@", dstPath, error);

            [self deleteFilenameInDatabase:db];

            [self cancel];

            return NO;
        }
    }

    // Move temp file to correct location in blob store:
    if (![defaultManager moveItemAtPath:_tempPath toPath:dstPath error:&error]) {
        os_log_error(CDTOSLog, "File not moved to final destination %{public}@: %{public}@", dstPath, error);

        [self deleteFilenameInDatabase:db];

        [self cancel];

        return NO;
    }

    // Return
    _tempPath = nil;

    return YES;
}

- (void)cancel
{
    [self closeFile];
    if (_tempPath) {
        [[NSFileManager defaultManager] removeItemAtPath:_tempPath error:NULL];
        _tempPath = nil;
    }
}

- (void)dealloc
{
    [self cancel];  // Close file, and delete it if it hasn't been installed yet
}

#pragma mark - TDBlobStore+Internal methods
- (NSString *)tempPath { return _tempPath; }

- (NSString *)filenameInDatabase:(FMDatabase *)db
{
    return [TD_Database filenameForKey:_blobKey inBlobFilenamesTableInDatabase:db];
}

- (NSString *)generateAndInsertRandomFilenameInDatabase:(FMDatabase *)db
{
    return [TD_Database generateAndInsertRandomFilenameBasedOnKey:_blobKey
                                 intoBlobFilenamesTableInDatabase:db];
}

- (BOOL)deleteFilenameInDatabase:(FMDatabase *)db
{
    return [TD_Database deleteRowForKey:_blobKey inBlobFilenamesTableInDatabase:db];
}

@end
