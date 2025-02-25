//
//  TDPuller.m
//  TouchDB
//
//  Created by Jens Alfke on 12/2/11.
//  Copyright © 2017, 2019 IBM Corp. All rights reserved.
//
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Modifications for this distribution by Cloudant, Inc., Copyright (c) 2014 Cloudant, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDPuller.h"
#import "TD_Database+Insertion.h"
#import "TD_Database+Replication.h"
#import "TD_Revision.h"
#import "TDChangeTracker.h"
#import "TDAuthorizer.h"
#import "TDBatcher.h"
#import "TDMultipartDownloader.h"
#import "TDSequenceMap.h"
#import "TDInternal.h"
#import "TDMisc.h"
#import "ExceptionUtils.h"
#import "TDJSON.h"
#import "CDTLogging.h"
#import "CollectionUtils.h"
#import "Test.h"

// Maximum number of revisions to fetch simultaneously. (CFNetwork will only send about 5
// simultaneous requests, but by keeping a larger number in its queue we ensure that it doesn't
// run out, even if the TD thread doesn't always have time to run.)
#define kMaxOpenHTTPConnections 12

// ?limit= param for _changes feed: max # of revs to get in one batch. Smaller values reduce
// latency since we can't parse till the entire result arrives in longpoll mode. But larger
// values are more efficient because they use fewer HTTP requests.
#define kChangesFeedLimit 100u

// Maximum number of revs to fetch in a single bulk request
#define kMaxRevsToGetInBulk 50u

// Maximum number of revision IDs to pass in an "?atts_since=" query param
#define kMaxNumberOfAttsSince 50u

@interface TDPuller () <TDChangeTrackerClient>

@property bool stopping;

@end

static NSString* joinQuotedEscaped(NSArray* strings);

@implementation TDPuller

- (instancetype)initWithDB:(TD_Database*)db
                    remote:(NSURL*)remote
                      push:(BOOL)push
                continuous:(BOOL)continuous
              interceptors:(NSArray*)interceptors
{
    if (self = [super initWithDB:db remote:remote push:push continuous:continuous interceptors:interceptors])
    {
        NSUInteger initialRevsCapacity = 100;
        _deletedRevsToPull = [[NSMutableArray alloc] initWithCapacity:initialRevsCapacity];
        _revsToPull = [[NSMutableArray alloc] initWithCapacity:initialRevsCapacity];
        _bulkGetRevs = [[NSMutableArray alloc] initWithCapacity:initialRevsCapacity];
        _bulkRevsToPull = [[NSMutableArray alloc] initWithCapacity:initialRevsCapacity];
        _stopping = NO;
    }
    return self;
}

- (void)dealloc { [_changeTracker stop]; }

- (void)testBulkGet:(NSDictionary* _Nullable )requestBody handler:(ReplicatorTestCompletionHandler) completionHandler {
    [self sendAsyncRequest:@"POST" path:@"_bulk_get" body:requestBody onCompletion:completionHandler];
}

- (void)beginReplicating
{
    __weak TDPuller* weakSelf = self;
    // check to see if _bulk_get endpoint is supported and then start replication
    NSArray* keys = [NSArray array];
    NSDictionary *requestBody = @{@"docs": keys};
    __block bool done = NO;
    [self sendAsyncRequest:@"POST"
                      path:@"_bulk_get"
                      body:requestBody
              onCompletion:^(id result, NSError* error) {
                  __strong TDPuller* strongSelf = weakSelf;
                  switch(error.code) {
                      case 404:
                          // not found: _bulk_get not supported
                          [strongSelf setBulkGetSupported:false];
                          os_log_info(CDTOSLog, "%{public}@ Remote database does not support _bulk_get", self);
                          break;
                      case 405:
                          // method not allowed: this endpoint exists, we called with the wrong method
                          [strongSelf setBulkGetSupported:true];
                          os_log_info(CDTOSLog, "%{public}@ Remote database supports _bulk_get", self);
                          break;
                      default:
                          [strongSelf setBulkGetSupported:false];
                          os_log_debug(CDTOSLog, "%{public}@ Remote database returned unexpected status code %ld when trying to determine whether database supports _bulk_get. Defaulting to _bulk_get not supported.", self, error.code);
                  }
                  done = YES;
              }];
    
    while (!done) {
        [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                 beforeDate: [NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    // on completion...start the actual replication
    if (!_downloadsToInsert) {
        // Note: This is a ref cycle, because the block has a (retained) reference to 'self',
        // and _downloadsToInsert retains the block, and of course I retain _downloadsToInsert.
        _downloadsToInsert = [[TDBatcher alloc]
            initWithCapacity:200
                       delay:1.0
                   processor:^(NSArray* downloads) { [self insertDownloads:downloads]; }];
    }
    if (!_pendingSequences) {
        _pendingSequences = [[TDSequenceMap alloc] init];
        if (_lastSequence != nil) {
            // Prime _pendingSequences so its checkpointedValue will reflect the last known seq:
            SequenceNumber seq = [_pendingSequences addValue:_lastSequence];
            [_pendingSequences removeSequence:seq];
            AssertEqual(_pendingSequences.checkpointedValue, _lastSequence);
        }
    }

    _caughtUp = NO;
    [self asyncTaskStarted];  // task: waiting to catch up
    [self startChangeTracker];
}

- (void)startChangeTracker
{

    Assert(!_changeTracker);
    //continuous / longpoll modes are not supported or available at the CDT* level.
    //As such, the new TDURLConnectionChangeTracker also only supports one-shot query
    //to the _changes feed. 
    TDChangeTrackerMode mode = kOneShot;

    os_log_info(CDTOSLog, "%{public}@ starting ChangeTracker: mode=%{public}d, since=%{public}@", self, mode, _lastSequence);
    _changeTracker = [[TDChangeTracker alloc] initWithDatabaseURL:_remote
                                                             mode:mode
                                                        conflicts:YES
                                                     lastSequence:_lastSequence
                                                           client:self
                                                          session:self.session];
    // Limit the number of changes to return, so we can parse the feed in parts:
    _changeTracker.limit = kChangesFeedLimit;
    _changeTracker.filterName = _filterName;
    _changeTracker.filterParameters = _filterParameters;
    _changeTracker.docIDs = _docIDs;
    _changeTracker.authorizer = _authorizer;
    unsigned heartbeat = self.heartbeat.unsignedIntValue;
    if (heartbeat >= 15000) _changeTracker.heartbeat = heartbeat / 1000.0;

    //make sure we don't overwrite a custom user-agent header
    BOOL hasUserAgentHeader = NO;
    for (NSString *key in self.requestHeaders) {
        if ([[key lowercaseString] isEqualToString:@"user-agent"]) {
            hasUserAgentHeader = YES;
            break;
        }
    }
    NSMutableDictionary* headers = [NSMutableDictionary dictionaryWithDictionary:_requestHeaders];
    NSString *userAgent = [TDRemoteRequest userAgentHeader];
    if (!hasUserAgentHeader && userAgent) {
        headers[@"User-Agent"] = userAgent;
    }
   
    _changeTracker.requestHeaders = headers;

    [_changeTracker start];
    if (!_continuous) [self asyncTaskStarted];
}

- (void)stop
{
    @synchronized(self) {
        _stopping = YES;
        if (!_running) return;
        if (_changeTracker) {
            _changeTracker.client = nil;  // stop it from calling my -changeTrackerStopped
            [_changeTracker stop];
            if (!_continuous)
                [self asyncTasksFinished:1];  // balances -asyncTaskStarted in -startChangeTracker
            if (!_caughtUp)
                [self asyncTasksFinished:1];  // balances -asyncTaskStarted in -beginReplicating
        }
        _changeTracker = nil;
        [super stop];

        [_downloadsToInsert flushAll];
    }
}

- (void)retry
{
    // This is called if I've gone idle but some revisions failed to be pulled.
    // I should start the _changes feed over again, so I can retry all the revisions.
    [super retry];
    [_changeTracker stop];
    [self beginReplicating];
}

- (void)stopped
{
    @synchronized(self) {
        // only want stopped to run once
        if (!_running) {
            return;
        }
        _downloadsToInsert = nil;
        [_revsToPull removeAllObjects];
        [_deletedRevsToPull removeAllObjects];
        [_bulkRevsToPull removeAllObjects];
        [_bulkGetRevs removeAllObjects];
        [super stopped];
    }
}

- (BOOL)goOnline
{
    if ([super goOnline]) return YES;
    // If we were already online (i.e. server is reachable) but got a reachability-change event,
    // tell the tracker to retry in case it's in retry mode after a transient failure. (I.e. the
    // state of the network might be better now.)
    if (_running && _online) [_changeTracker retry];
    return NO;
}

- (BOOL)goOffline
{
    if (![super goOffline]) return NO;
    [_changeTracker stop];
    return YES;
}

// Got a _changes feed response from the TDChangeTracker.
- (void)changeTrackerReceivedChanges:(NSArray*)changes
{
    os_log_info(CDTOSLog, "%{public}@: Received %{public}u changes", self, (unsigned)changes.count);
    NSUInteger changeCount = 0;
    for (NSDictionary* change in changes) {
        @autoreleasepool
        {
            // Process each change from the feed:
            id remoteSequenceID = change[@"seq"];
            NSString* docID = change[@"id"];
            if (!docID || ![TD_Database isValidDocumentID:docID]) continue;

            BOOL deleted = [change[@"deleted"] isEqual:(id)kCFBooleanTrue];
            NSArray* changes = $castIf(NSArray, change[@"changes"]);
            for (NSDictionary* changeDict in changes) {
                @autoreleasepool
                {
                    // Push each revision info to the inbox
                    NSString* revID = $castIf(NSString, changeDict[@"rev"]);
                    if (!revID) continue;
                    TDPulledRevision* rev =
                        [[TDPulledRevision alloc] initWithDocID:docID revID:revID deleted:deleted];
                    // Remember its remote sequence ID (opaque), and make up a numeric sequence
                    // based on the order in which it appeared in the _changes feed:
                    rev.remoteSequenceID = remoteSequenceID;
                    if (changes.count > 1) rev.conflicted = true;
                    os_log_debug(CDTOSLog, "%{public}@: Received #%{public}@ %{public}@", self, remoteSequenceID, rev);
                    [self addToInbox:rev];

                    changeCount++;
                }
            }
        }
    }
    self.changesTotal += changeCount;

    // We can tell we've caught up when the _changes feed returns less than we asked for:
    if (!_caughtUp && changes.count < kChangesFeedLimit) {
        os_log_info(CDTOSLog, "%{public}@: Caught up with changes!", self);
        _caughtUp = YES;
        if (_continuous) _changeTracker.mode = kLongPoll;
        [self asyncTasksFinished:1];  // balances -asyncTaskStarted in -beginReplicating
    }
}

// The change tracker reached EOF or an error.
- (void)changeTrackerStopped:(TDChangeTracker*)tracker
{
    if (tracker != _changeTracker) return;
    NSError* error = tracker.error;
    os_log_info(CDTOSLog, "%{public}@: ChangeTracker stopped; error=%{public}@", self, error.description);

    _changeTracker = nil;

    if (error) {
        if (TDIsOfflineError(error))
            [self goOffline];
        else if (!_error)
            self.error = error;
    }

    [_batcher flushAll];
    if (!_continuous)
        [self asyncTasksFinished:1];  // balances -asyncTaskStarted in -startChangeTracker
    if (!_caughtUp) [self asyncTasksFinished:1];  // balances -asyncTaskStarted in -beginReplicating
}

- (NSUInteger)sizeOfChangeQueue { return _revsToPull.count; }
#pragma mark - REVISION CHECKING:

// Process a bunch of remote revisions from the _changes feed at once
- (void)processInbox:(nullable TD_RevisionList*)inbox
{
    // Ask the local database which of the revs are not known to it:
    os_log_debug(CDTOSLog, "%{public}@: Looking up %{public}@", self, inbox);
    id lastInboxSequence = [inbox.allRevisions.lastObject remoteSequenceID];
    NSUInteger total = _changesTotal - inbox.count;
    if (![_db findMissingRevisions:inbox]) {
        os_log_debug(CDTOSLog, "%{public}@ failed to look up local revs", self);
        inbox = nil;
    }
    if (_changesTotal != total + inbox.count) self.changesTotal = total + inbox.count;

    if (inbox.count == 0) {
        // Nothing to do; just count all the revisions as processed.
        // Instead of adding and immediately removing the revs to _pendingSequences,
        // just do the latest one (equivalent but faster):
        os_log_debug(CDTOSLog, "%{public}@: no new remote revisions to fetch", self);
        SequenceNumber seq = [_pendingSequences addValue:lastInboxSequence];
        [_pendingSequences removeSequence:seq];
        self.lastSequence = _pendingSequences.checkpointedValue;
        return;
    }

    os_log_debug(CDTOSLog, "%{public}@ queuing remote revisions %{public}@", self, inbox.allRevisions);

    // Dump the revs into the queues of revs to pull from the remote db:
    unsigned numBulked = 0;
    for (TDPulledRevision* rev in inbox.allRevisions) {
        if (!_bulkGetSupported && rev.generation == 1 && !rev.deleted && !rev.conflicted) {
            // Optimistically pull 1st-gen revs in bulk:
            [_bulkRevsToPull addObject:rev];
            ++numBulked;
        } else {
            [self queueRemoteRevision:rev];
        }
        rev.sequence = [_pendingSequences addValue:rev.remoteSequenceID];
    }
    os_log_info(CDTOSLog, "%{public}@ queued %{public}u remote revisions from seq=%{public}@ (%{public}u in bulk, %{public}u individually)", self, (unsigned)inbox.count, ((TDPulledRevision*)inbox[0]).remoteSequenceID, numBulked, (unsigned)(inbox.count - numBulked));

    [self pullRemoteRevisions];
}

// Add a revision to the appropriate queue of revs to individually GET
- (void)queueRemoteRevision:(TD_Revision*)rev
{
    if (_bulkGetSupported) {
        [_bulkGetRevs addObject:rev];
    } else {
        if (rev.deleted) {
            [_deletedRevsToPull addObject:rev];
        } else {
            [_revsToPull addObject:rev];
        }
    }
}

// Start up some HTTP GETs, within our limit on the maximum simultaneous number
- (void)pullRemoteRevisions
{
    while (!_stopping && _db && _httpConnectionCount < kMaxOpenHTTPConnections) {
        NSUInteger nBulk = MIN(_bulkGetRevs.count, kMaxRevsToGetInBulk);
        
        // Process from _bulkGetRevs first if there are any.
        // If the server supports _bulk_get but there are deleted revisions
        // then we will fall through to the 'deleted revs' case later, once
        // _bulkGetRevs is empty
        if (nBulk > 0) {
            NSRange r = NSMakeRange(0, nBulk);
            [self pullBulkRevisionsBulkGet:[_bulkGetRevs subarrayWithRange:r]];
            [_bulkGetRevs removeObjectsInRange:r];
            
        } else {
            NSUInteger nBulk = MIN(_bulkRevsToPull.count, kMaxRevsToGetInBulk);
            
            if (nBulk == 1) {
                // Rather than pulling a single revision in 'bulk', just pull it normally:
                [self queueRemoteRevision:_bulkRevsToPull[0]];
                [_bulkRevsToPull removeObjectAtIndex:0];
                nBulk = 0;
            }
            if (nBulk > 0) {
                // Prefer to pull bulk revisions:
                NSRange r = NSMakeRange(0, nBulk);
                [self pullBulkRevisionsWithAllDocs:[_bulkRevsToPull subarrayWithRange:r]];
                [_bulkRevsToPull removeObjectsInRange:r];
            } else {
                // Prefer to pull an existing revision over a deleted one:
                NSMutableArray* queue = _revsToPull;
                if (queue.count == 0) {
                    queue = _deletedRevsToPull;
                    if (queue.count == 0) break;  // both queues are empty
                }
                [self pullRemoteRevision:queue[0]];
                [queue removeObjectAtIndex:0];
            }
        }
    }
}

// Fetches the contents of a revision from the remote db, including its parent revision ID.
// The contents are stored into rev.properties.
- (void)pullRemoteRevision:(TD_Revision*)rev
{
    [self asyncTaskStarted];
    ++_httpConnectionCount;

    // Construct a query. We want the revision history, and the bodies of attachments that have
    // been added since the latest revisions we have locally.
    // See: http://wiki.apache.org/couchdb/HTTP_Document_API#GET
    // See: http://wiki.apache.org/couchdb/HTTP_Document_API#Getting_Attachments_With_a_Document
    NSString* path = $sprintf(@"%@?rev=%@&latest=true&revs=true&attachments=true", TDEscapeID(rev.docID),
                              TDEscapeID(rev.revID));
    NSArray* knownRevs = [_db getPossibleAncestorRevisionIDs:rev limit:kMaxNumberOfAttsSince];
    if (knownRevs.count > 0)
        path = [path stringByAppendingFormat:@"&atts_since=%@", joinQuotedEscaped(knownRevs)];
    os_log_debug(CDTOSLog, "%{public}@: GET %{public}@", self, path);

    // Under ARC, using variable dl directly in the block given as an argument to initWithURL:...
    // results in compiler error (could be undefined variable)
    __weak TDPuller* weakSelf = self;
    TDMultipartDownloader* dl;
    dl = [[TDMultipartDownloader alloc] initWithSession:self.session URL:TDAppendToURL(_remote, path)
                                               database:_db
                                         requestHeaders:self.requestHeaders
                                           onCompletion:^(TDMultipartDownloader* dl, NSError* error) {
                                               __strong TDPuller* strongSelf = weakSelf;
                                               // OK, now we've got the response revision:
                                               if (error) {
                                                   strongSelf.error = error;
                                                   [strongSelf revisionFailed];
                                                   strongSelf.changesProcessed++;
                                               } else {
                                                   TD_Revision* gotRev =
                                                       [TD_Revision revisionWithProperties:dl.document];
                                                   gotRev.sequence = rev.sequence;
                                                   // Add to batcher ... eventually it will be fed to
                                                   // -insertRevisions:.
                                                   [self->_downloadsToInsert queueObject:gotRev];
                                                   [strongSelf asyncTaskStarted];
                                               }
                                               
                                               // Start another task if there are still revisions
                                               // waiting to be pulled:
                                               [strongSelf pullRemoteRevisions];
                                               // Note that we've finished this task:
                                               [strongSelf removeRemoteRequest:dl];
                                               [strongSelf asyncTasksFinished:1];
                                               --self->_httpConnectionCount;
                                           }];
    [self addRemoteRequest:dl];
    dl.authorizer = _authorizer;
    [dl start];
}

- (void)pullBulkRevisionsBulkGet:(NSArray*)bulkRevs
{
    // http://wiki.apache.org/couchdb/HTTP_Bulk_Document_API
    NSUInteger nRevs = bulkRevs.count;
    if (nRevs == 0) return;
    os_log_info(CDTOSLog, "%{public}@ bulk-fetching (via _bulk_get) %{public}u remote revisions...", self, (unsigned)nRevs);
    os_log_debug(CDTOSLog, "%{public}@ bulk-fetching (via _bulk_get) remote revisions: %{public}@", self, bulkRevs);
    
    [self asyncTaskStarted];
    ++_httpConnectionCount;
    
    // body needs to be in form:
    // {"docs":[{"id":"1-foo","rev":"rev123","atts_since":["1-foo,...]}]}
    NSArray* keys = [bulkRevs my_map:^(TD_Revision* rev) {
        NSArray* knownRevs = [self->_db getPossibleAncestorRevisionIDs:rev limit:kMaxNumberOfAttsSince];
        return @{@"id": rev.docID,
                 @"rev": rev.revID,
                 @"atts_since": knownRevs != nil ? knownRevs : @[]};
    }];
    
    NSDictionary *requestBody = @{@"docs": keys};    
    NSMutableArray* remainingRevs = [bulkRevs mutableCopy];
    __weak TDPuller* weakSelf = self;

    [self sendAsyncRequest:@"POST"
                      path:@"_bulk_get?latest=true&revs=true&attachments=true"
                      body:requestBody
              onCompletion:^(id result, NSError* error) {
                  __strong TDPuller* strongSelf = weakSelf;
                  if (error) {
                      strongSelf.error = error;
                      [strongSelf revisionFailed];
                      strongSelf.changesProcessed+=bulkRevs.count;
                  } else if ($castIf(NSDictionary, result) != nil) {
                      // unpack revisions and queue them in _downloadsToInsert
                      NSArray *results = $castIf(NSArray, result[@"results"]);
                      for (NSDictionary *docResult in results) {
                          // skip if it's not a dictionary
                          if (![docResult isKindOfClass:[NSDictionary class]]) {
                              break;
                          }
                          NSArray *docs = $castIf(NSArray, docResult[@"docs"]);
                          for (NSDictionary *doc in docs) {
                              // skip if it's not a dictionary
                              if (![doc isKindOfClass:[NSDictionary class]]) {
                                  break;
                              }
                              NSDictionary *okRevision = $castIf(NSDictionary, doc[@"ok"]);
                              if (okRevision != nil) {
                                  TD_Revision* rev = [TD_Revision revisionWithProperties:okRevision];
                                  NSUInteger pos = [remainingRevs indexOfObject:rev];
                                  if (pos != NSNotFound) {
                                      rev.sequence = [remainingRevs[pos] sequence];
                                      [remainingRevs removeObjectAtIndex:pos];
                                      [self->_downloadsToInsert queueObject:rev];
                                      [self asyncTaskStarted];
                                  }
                              } else {
                                  os_log_debug(CDTOSLog, "%{public}@ no \"ok\" revision found in _bulk_get response for docid=%{public}@, revid=%{public}@", self, doc[@"_id"], doc[@"_rev"]);
                              }
                          }
                      }
                  }
                  
                  [self asyncTasksFinished:1];
                  --self->_httpConnectionCount;
                  // Start another task if there are still revisions waiting to be pulled:
                  [self pullRemoteRevisions];
              }];
}

// Get a bunch of revisions in one bulk request.
- (void)pullBulkRevisionsWithAllDocs:(NSArray*)bulkRevs
{
    // http://wiki.apache.org/couchdb/HTTP_Bulk_Document_API
    NSUInteger nRevs = bulkRevs.count;
    if (nRevs == 0) return;
    os_log_info(CDTOSLog, "%{public}@ bulk-fetching (via _all_docs) %{public}u remote revisions...", self, (unsigned)nRevs);
    os_log_debug(CDTOSLog, "%{public}@ bulk-fetching (via _all_docs) remote revisions: %{public}@", self, bulkRevs);

    [self asyncTaskStarted];
    ++_httpConnectionCount;
    NSMutableArray* remainingRevs = [bulkRevs mutableCopy];
    NSArray* keys = [bulkRevs my_map:^(TD_Revision* rev) { return rev.docID; }];
    [self sendAsyncRequest:@"POST"
                      path:@"_all_docs?include_docs=true"
                      body:$dict({ @"keys", keys })
              onCompletion:^(id result, NSError* error) {
                  if (error) {
                      self.error = error;
                      [self revisionFailed];
                      self.changesProcessed += bulkRevs.count;
                  } else {
                      // Process the resulting rows' documents.
                      // We only add a document if it doesn't have attachments, and if its
                      // revID matches the one we asked for.
                      NSArray* rows = $castIf(NSArray, result[@"rows"]);
                      os_log_info(CDTOSLog, "%{public}@ checking %{public}u bulk-fetched remote revisions", self, (unsigned)rows.count);
                      for (NSDictionary* row in rows) {
                          NSDictionary* doc = $castIf(NSDictionary, row[@"doc"]);
                          if (doc && !doc[@"_attachments"]) {
                              TD_Revision* rev = [TD_Revision revisionWithProperties:doc];
                              NSUInteger pos = [remainingRevs indexOfObject:rev];
                              if (pos != NSNotFound) {
                                  rev.sequence = [remainingRevs[pos] sequence];
                                  [remainingRevs removeObjectAtIndex:pos];
                                  [self->_downloadsToInsert queueObject:rev];
                                  [self asyncTaskStarted];
                              }
                          }
                      }
                  }

                  // Any leftover revisions that didn't get matched will be fetched individually:
                  if (remainingRevs.count) {
                      os_log_info(CDTOSLog, "%{public}@ bulk-fetch didn't work for %{public}u of %{public}u revs; getting individually", self, (unsigned)remainingRevs.count, (unsigned)nRevs);
                      for (TD_Revision* rev in remainingRevs) [self queueRemoteRevision:rev];
                      [self pullRemoteRevisions];
                  }

                  // Note that we've finished this task:
                  [self asyncTasksFinished:1];
                  --self->_httpConnectionCount;
                  // Start another task if there are still revisions waiting to be pulled:
                  [self pullRemoteRevisions];
              }];
}

// This will be called when _downloadsToInsert fills up:
- (void)insertDownloads:(NSArray*)downloads
{
    os_log_debug(CDTOSLog, "%{public}@ inserting %{public}u revisions...", self, (unsigned)downloads.count);
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();

    @try {
        downloads = [downloads sortedArrayUsingSelector:@selector(compareSequences:)];
        for (TD_Revision* rev in downloads) {
            @autoreleasepool
            {
                SequenceNumber fakeSequence = rev.sequence;
                NSArray* history = [TD_Database parseCouchDBRevisionHistory:rev.properties];
                if (!history && rev.generation > 1) {
                    os_log_debug(CDTOSLog, "%{public}@: Missing revision history in response for %{public}@", self, rev);
                    self.error = TDStatusToNSError(kTDStatusUpstreamError, nil);
                    [self revisionFailed];
                    continue;
                }
                os_log_debug(CDTOSLog, "%{public}@ inserting %{public}@ %{public}@", self, rev.docID, [history my_compactDescription]);

                // Insert the revision:
                TDStatus status = [_db forceInsert:rev revisionHistory:history source:_remote];
                if (TDStatusIsError(status)) {
                    if (status == kTDStatusForbidden)
                    os_log_info(CDTOSLog, "%{public}@: Remote rev failed validation: %{public}@", self, rev);
                    else {
                        os_log_debug(CDTOSLog, "%{public}@ failed to write %{public}@: status=%{public}d", self, rev, (int)status);
                        [self revisionFailed];
                        self.error = TDStatusToNSError(status, nil);
                        continue;
                    }
                }

                // Mark this revision's fake sequence as processed:
                [_pendingSequences removeSequence:fakeSequence];
            }
        }

        [_db clearPendingAttachments];

        os_log_debug(CDTOSLog, "%{public}@ finished inserting %{public}u revisions", self, (unsigned)downloads.count);

        // Checkpoint:
        self.lastSequence = _pendingSequences.checkpointedValue;
    }
    @catch (NSException* x) { MYReportException(x, @"%@: Exception inserting revisions", self); }
    
    time = CFAbsoluteTimeGetCurrent() - time;
    os_log_info(CDTOSLog, "%{public}@ inserted %{public}u revs in %{public}.3f sec (%{public}.1f/sec)", self, (unsigned)downloads.count, time, downloads.count / time);

    self.changesProcessed += downloads.count;
    [self asyncTasksFinished:downloads.count];
}

@end

#pragma mark -

@implementation TDPulledRevision

@synthesize remoteSequenceID = _remoteSequenceID, conflicted = _conflicted;

@end

static NSString* joinQuotedEscaped(NSArray* strings)
{
    if (strings.count == 0) return @"[]";
    NSString* json = [TDJSON stringWithJSONObject:strings options:0 error:NULL];
    return TDEscapeURLParam(json);
}
