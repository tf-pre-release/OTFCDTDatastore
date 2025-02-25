//
//  CDTDatastore.h
//  CloudantSync
//
//  Created by Michael Rhodes on 02/07/2013.
//  Copyright (c) 2013 Cloudant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <Foundation/Foundation.h>
#import "CDTDatastoreManager.h"
#import "CDTNSURLSessionConfigurationDelegate.h"
#if TARGET_OS_IPHONE
#import <OTFToolBoxCore/OTFToolBoxCore-Swift.h>
#endif

@class CDTDocumentRevision;
@class FMDatabase;

/** NSNotification posted when a document is updated.
 UserInfo keys:
  - @"rev": the new CDTDocumentRevision,
  - @"source": NSURL of remote db pulled from,
  - @"winner": new winning CDTDocumentRevision, _if_ it changed (often same as rev).
 */
extern NSString * __nonnull const CDTDatastoreChangeNotification;

@class TD_Database;

/**
 * The CDTDatastore is the core interaction point for create, delete and update
 * operations (CRUD) for within Cloudant Sync.
 *
 * The Datastore can be viewed as a pool of heterogeneous JSON documents. One
 * datastore can hold many different types of document, unlike tables within a
 * relational model. The datastore provides hooks, which allow for various querying models
 * to be built on top of its simpler key-value model.
 *
 * Each document consists of a set of revisions, hence most methods within
 * this class operating on CDTDocumentRevision objects, which carry both a
 * document ID and a revision ID. This forms the basis of the MVCC data model,
 * used to ensure safe peer-to-peer replication is possible.
 *
 * Each document is formed of a tree of revisions. Replication can create
 * branches in this tree when changes have been made in two or more places to
 * the same document in-between replications. MVCC exposes these branches as
 * conflicted documents. These conflicts should be resolved by user-code, by
 * using the conflict resolution APIs. When the datastore is next replicated with a remote
 * datastore, this fix will be propagated, thereby resolving the conflicted document across the
 * set of peers.
 *
 * See CDTDatastore+Conflicts.h for functions to resolve Document conflicts caused by
 * replication.
 *
 * @see CDTDocumentRevision
 *
 */
@interface CDTDatastore : NSObject

@property (nullable, nonatomic, strong, readonly) TD_Database *database;

+ (nonnull NSString *)versionString;

@property (nonnull, strong) NSString *directory;




/**
 * Encryption Modes allowed at present.
 *
 * @param RunToCompletionWithin10Seconds Apps are guaranteed to complete syncing within 10 seconds, it will set NSFileProtectionType to CompleteUnlessOpen till 10 seconds finishes. After 10 seconds it will be change to NSFileProtectionType to Complete automatically and any running syncing won't be able to access Files if application is in background.
 *
 * @param RunToCompletionBeyond10Seconds Apps cannot complete syncing within 10 seconds and need more time, RunToCompletionBeyond10Seconds will give 20 seconds timeframe to finish any running syncing. After 20 seconds it will be change to NSFileProtectionType to Complete automatically and any running syncing won't be able to access Files if application is in background.
 *
 * @param BackgroundMode Apps need to periodically run in the background to do things such as automatic syncs. It will give 30 seconds timeframe to finish any operation  in the background. After 30 seconds it will be change to NSFileProtectionType to Complete automatically and any running operation won't be able to access Files because application is in background.
 *


typedef NS_ENUM(NSUInteger, OTFProtectionLevel) {
    RunToCompletionWithin10Seconds = 1,
    RunToCompletionBeyond10Seconds = 2,
    BackgroundMode = 3
};
 */

/**
 *
 * Creates a CDTDatastore instance.
 *
 * @param manager this datastore's manager, must not be nil.
 * @param database the database where this datastore should save documents.
 *
 */
- (nullable instancetype)initWithManager:(nonnull CDTDatastoreManager *)manager database:(nonnull TD_Database *)database directory: (nonnull NSString *)directory;
/**
 * The number of document in the datastore.
 */
@property (readonly) NSUInteger documentCount;

/**
 * The name of the datastore.
 */
@property (nonnull, readonly) NSString *name;

/**
 * The name of the datastore.
 */
@property (nonnull, readonly) NSString *extensionsDir;

/**
 * Returns a document's current winning revision.
 *
 * @param docId id of the specified document
 * @param error will point to an NSError object in case of error.
 *
 * @return current revision as CDTDocumentRevision of given document
 */
- (nullable CDTDocumentRevision *)getDocumentWithId:(nonnull NSString *)docId
                                              error:(NSError *__nullable * __nullable)error;

/**
 * Return a specific revision of a document.
 *
 * This method gets the revision of a document with a given ID. As the
 * datastore prunes the content of old revisions to conserve space, this
 * revision may contain the metadata but not content of the revision.
 *
 * @param docId id of the specified document
 * @param rev id of the specified revision
 * @param error will point to an NSError object in case of error.
 *
 * @return specified CDTDocumentRevision of the document for given
 *     document id or nil if it doesn't exist
 */
- (nullable CDTDocumentRevision *)getDocumentWithId:(nonnull NSString *)docId
                                                rev:(nullable NSString *)rev
                                              error:(NSError *__nullable *  __nullable)error;

/**
 * Unpaginated read of all documents.
 *
 * All documents are read into memory before being returned.
 *
 * Only the current winning revision of each document is returned.
 *
 * @return NSArray of CDTDocumentRevisions
 */
- (nullable NSArray<CDTDocumentRevision*> *)getAllDocuments;

/**
 * Enumerates the current winning revision for all documents in the
 * datastore and return a list of their document identifiers.
 *
 * @return NSArray of NSStrings
 */
- (nullable NSArray<NSString*> *)getAllDocumentIds;

/**
 * Enumerate the current winning revisions for all documents in the
 * datastore.
 *
 * Logically, this method takes all the documents in either ascending
 * or descending order, skips all documents up to `offset` then
 * returns up to `limit` document revisions, stopping either
 * at `limit` or when the list of document is exhausted.
 *
 * Note that if the datastore changes between calls using offset/limit,
 * documents may be missed out.
 *
 * @param offset    start position
 * @param limit maximum number of documents to return
 * @param descending ordered descending if true, otherwise ascendingly
 * @return NSArray containing CDTDocumentRevision objects
 */
- (nonnull NSArray<CDTDocumentRevision*> *)getAllDocumentsOffset:(NSUInteger)offset
                             limit:(NSUInteger)limit
                        descending:(BOOL)descending;

/**
 * Return the winning revisions for a set of document IDs.
 *
 * @param docIds list of document id
 *
 * @return NSArray containing CDTDocumentRevision objects
 */
- (nonnull NSArray<CDTDocumentRevision*> *)getDocumentsWithIds:(nonnull NSArray *)docIds;

/**
 * Returns the history of revisions for the passed revision.
 *
 * This is each revision on the branch that `revision` is on,
 * from `revision` to the root of the tree.
 *
 * Older revisions will not contain the document data as it will have
 * been compacted away.
 */
- (nonnull NSArray<CDTDocumentRevision*> *)getRevisionHistory:(nonnull CDTDocumentRevision *)revision;

/**
 * Return a directory for an extension to store its data for this CDTDatastore.
 *
 * @param extensionName name of the extension
 *
 * @return the directory for specified extensionName
 */
- (nonnull NSString *)extensionDataFolder:(nonnull NSString *)extensionName;

#pragma mark API V2
/**
 * Creates a document from a MutableDocumentRevision
 *
 * @param revision document revision to create document from
 * @param error will point to an NSError object in the case of an error
 *
 * @return document revision created
 */
- (nullable CDTDocumentRevision *)createDocumentFromRevision:(nonnull CDTDocumentRevision *)revision
                                                       error:(NSError *__nullable * __nullable )error;

/**
 * Updates a document in the datastore with a new revision
 *
 *  @parm revision updated document revision
 *  @param error will point to an NSError object in the case of an error
 *
 *  @return the updated document
 *
 */
- (nullable CDTDocumentRevision *)updateDocumentFromRevision:(nonnull CDTDocumentRevision *)revision
                                                       error:(NSError *__nullable * __nullable )error;
/**
 * Deletes a document from the datastore.
 *
 * @param revision document to delete from the datastore
 * @param error will point to an NSError object in the case of an error
 *
 * @return the deleted document
 */
- (nullable CDTDocumentRevision *)deleteDocumentFromRevision:(nonnull CDTDocumentRevision *)revision
                                                       error:(NSError *__nullable * __nullable)error;

/**
 *
 * Delete a document and all leaf revisions.
 *
 * @param docId ID of the document
 * @param error will point to an NSError object in the case of an error
 *
 * @return an array of deleted documents
 *
 */
- (nullable NSArray *)deleteDocumentWithId:(nonnull NSString *)docId error:(NSError *__nullable * __nullable)error;

/**
 *
 * Compact local database, deleting document bodies, keeping only the metadata of
 * previous revisions
 *
 * @param error will point to an NSError object in the case of an error
 */
- (BOOL)compactWithError:(NSError *__nullable * __nullable)error;

#if TARGET_OS_IPHONE
/// This function will help to set FILE Protection manually by users.
/// @param type Its FileProtection Type Enum provided by Apple, user can pass any Protection case whatever they need to set on there files.
-(void)encryptFile: (NSFileProtectionType _Nonnull)type;

///  This function will help to set Protection level. Set a mode according to your need.
/// @param level - It's a ENUM value that users can set from predefined enum cases.
-(void)setProtectionLevel: (OTFProtectionLevel)level error:(NSError *__nullable * __nullable)error;

/// This funtion will return the current applied file protection policy on files.
- (NSFileProtectionType _Nullable)appliedProtectionPolicyOnDb;
#endif

/**
 * Set the delegate for handling customisation of the NSURLSession
 * used during replication.
 *
 * This allows the setting of specific options on the NSURLSessionConfiguration
 * to control the replication - e.g. replication only when on Wifi would be
 * achieved by setting the NSURLSessionConfiguration's allowsCellularAccess
 * attribute to 'NO'.
 *
 * @see CDTNSURLSessionConfigurationDelegate
 */

@property (nullable, nonatomic, weak) NSObject<CDTNSURLSessionConfigurationDelegate> *sessionConfigDelegate;
@end
