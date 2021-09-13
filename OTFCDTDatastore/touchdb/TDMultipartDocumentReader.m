//
//  TDMultipartDocumentReader.m
//  TouchDB
//
//  Created by Jens Alfke on 3/29/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
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

#import "TDMultipartDocumentReader.h"
#import "TD_Database+Attachments.h"
#import "TDBlobStore.h"
#import "TDInternal.h"
#import "TDBase64.h"
#import "TDMisc.h"
#import "CollectionUtils.h"
#import "MYStreamUtils.h"
#import "TDJSON.h"
#import "CDTLogging.h"
#import "Test.h"

@implementation TDMultipartDocumentReader

+ (NSDictionary*)readData:(NSData*)data
                   ofType:(NSString*)contentType
               toDatabase:(TD_Database*)database
                   status:(TDStatus*)outStatus
{
    if (data.length == 0) {
        *outStatus = kTDStatusBadJSON;
        return nil;
    }
    NSDictionary* result = nil;
    TDMultipartDocumentReader* reader = [[self alloc] initWithDatabase:database];
    if ([reader setContentType:contentType] && [reader appendData:data] && [reader finish]) {
        result = reader.document;
    }
    if (outStatus) *outStatus = reader.status;
    return result;
}

- (id)initWithDatabase:(TD_Database*)database
{
    Assert(database);
    self = [super init];
    if (self) {
        _database = database;
    }
    return self;
}

- (void)dealloc { [_curAttachment cancel]; }

@synthesize status = _status, document = _document;

- (NSUInteger)attachmentCount { return _attachmentsByDigest.count; }

- (BOOL)setContentType:(NSString*)contentType
{
    if ([contentType hasPrefix:@"multipart/"]) {
        // Multipart, so initialize the parser:
        os_log_info(CDTOSLog, "%{public}@: has attachments, %{public}@", self, contentType);
        _multipartReader =
            [[TDMultipartReader alloc] initWithContentType:contentType delegate:self];
        if (_multipartReader) {
            _attachmentsByName = [[NSMutableDictionary alloc] init];
            _attachmentsByDigest = [[NSMutableDictionary alloc] init];
            return YES;
        }
    } else if (contentType == nil || [contentType hasPrefix:@"application/json"]) {
        // No multipart, so no attachments. Body is pure JSON:
        _jsonBuffer = [[NSMutableData alloc] initWithCapacity:1024];
        return YES;
    }
    // Unknown/invalid MIME type:
    _status = kTDStatusNotAcceptable;
    return NO;
}

- (BOOL)appendData:(NSData*)data
{
    if (_multipartReader) {
        [_multipartReader appendData:data];
        if (_multipartReader.error) {
            os_log_debug(CDTOSLog, "%{public}@: received unparseable MIME multipart response: %{public}@", self,
                         _multipartReader.error);
            _status = kTDStatusUpstreamError;
            return NO;
        }
    } else {
        [_jsonBuffer appendData:data];
    }
    return YES;
}

- (BOOL)finish
{
    os_log_info(CDTOSLog, "%{public}@: Finished loading (%{public}u attachments)", self, (unsigned)_attachmentsByDigest.count);
    if (_multipartReader) {
        if (!_multipartReader.finished) {
            os_log_debug(CDTOSLog, "%{public}@: received incomplete MIME multipart response", self);
            _status = kTDStatusUpstreamError;
            return NO;
        }

        if (![self registerAttachments]) {
            _status = kTDStatusUpstreamError;
            return NO;
        }
    } else {
        if (![self parseJSONBuffer]) return NO;
    }
    _status = kTDStatusCreated;
    return YES;
}

#pragma mark - ASYNCHRONOUS MODE:

+ (TDStatus)readStream:(NSInputStream*)stream
                ofType:(NSString*)contentType
            toDatabase:(TD_Database*)database
                  then:(TDMultipartDocumentReaderCompletionBlock)onCompletion
{
    TDMultipartDocumentReader* reader = [[self alloc] initWithDatabase:database];
    return [reader readStream:stream ofType:contentType then:onCompletion];
}

- (TDStatus)readStream:(NSInputStream*)stream
                ofType:(NSString*)contentType
                  then:(TDMultipartDocumentReaderCompletionBlock)completionBlock
{
    if ([self setContentType:contentType]) {
        os_log_info(CDTOSLog, "%{public}@: Reading from input stream...", self);
        // balanced by release in -finishAsync:
        _completionBlock = [completionBlock copy];
        [stream open];
        stream.delegate = self;
        [stream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }
    return _status;
}

- (void)stream:(NSInputStream*)stream handleEvent:(NSStreamEvent)eventCode
{
    BOOL finish = NO;
    switch (eventCode) {
        case NSStreamEventHasBytesAvailable:
            finish = ![self readFromStream:stream];
            break;
        case NSStreamEventEndEncountered:
            finish = YES;
            break;
        case NSStreamEventErrorOccurred:
            os_log_debug(CDTOSLog, "%{public}@: error reading from stream: %{public}@", self,
                         stream.streamError);
            _status = kTDStatusUpstreamError;
            finish = YES;
            break;
        default:
            break;
    }
    if (finish) [self finishAsync:stream];
}

- (BOOL)readFromStream:(NSInputStream*)stream
{
    BOOL readOK = [stream my_readData:^(NSData* data) { [self appendData:data]; }];
    if (!readOK) {
        os_log_debug(CDTOSLog, "%{public}@: error reading from stream: %{public}@", self, stream.streamError);
        _status = kTDStatusUpstreamError;
    }
    return !TDStatusIsError(_status);
}

- (void)finishAsync:(NSInputStream*)stream
{
    stream.delegate = nil;
    [stream close];
    if (!TDStatusIsError(_status)) [self finish];
    _completionBlock(self);
    _completionBlock = nil;
    // balances -retain in -readStream:
}

#pragma mark - MIME PARSER CALLBACKS:

/** Callback: A part's headers have been parsed, but not yet its data. */
- (void)startedPart:(NSDictionary*)headers
{
    // First MIME part is the document's JSON body; the rest are attachments.
    if (!_document)
        _jsonBuffer = [[NSMutableData alloc] initWithCapacity:1024];
    else {
        os_log_info(CDTOSLog, "%{public}@: Starting attachment #%{public}u...", self, (unsigned)_attachmentsByDigest.count + 1);
        _curAttachment = [_database attachmentWriter];

        // See whether the attachment name is in the headers.
        NSString* disposition = headers[@"Content-Disposition"];
        if ([disposition hasPrefix:@"attachment; filename="]) {
            // TODO: Parse this less simplistically. Right now it assumes it's in exactly the same
            // format generated by -[TDPusher uploadMultipartRevision:]. CouchDB (as of 1.2) doesn't
            // output any headers at all on attachments so there's no compatibility issue yet.
            NSString* name = TDUnquoteString([disposition substringFromIndex:21]);
            if (name) _attachmentsByName[name] = _curAttachment;
        }
    }
}

/** Callback: Append data to a MIME part's body. */
- (void)appendToPart:(NSData*)data
{
    if (_jsonBuffer)
        [_jsonBuffer appendData:data];
    else
        [_curAttachment appendData:data];
}

/** Callback: A MIME part is complete. */
- (void)finishedPart
{
    if (_jsonBuffer) {
        [self parseJSONBuffer];
    } else {
        // Finished downloading an attachment. Remember the association from the MD5 digest
        // (which appears in the body's _attachments dict) to the blob-store key of the data.
        [_curAttachment finish];
        NSString* md5Str = _curAttachment.MD5DigestString;
#ifndef MY_DISABLE_LOGGING
        TDBlobKey key = _curAttachment.blobKey;
        NSData* keyData = [NSData dataWithBytes:&key length:sizeof(key)];
        os_log_debug(CDTOSLog, "%{public}@: Finished attachment #%{public}u: len=%{public}uk, digest=%{public}@, SHA1=%{public}@", self,
                     (unsigned)_attachmentsByDigest.count + 1, (unsigned)_curAttachment.length / 1024,
                     md5Str, keyData);

#endif
        _attachmentsByDigest[md5Str] = _curAttachment;
        _curAttachment = nil;
    }
}

#pragma mark - INTERNALS:

- (BOOL)parseJSONBuffer
{
    id document =
        [TDJSON JSONObjectWithData:_jsonBuffer options:TDJSONReadingMutableContainers error:NULL];
    if (![document isKindOfClass:[NSDictionary class]]) {
        os_log_debug(CDTOSLog, "%{public}@: received unparseable JSON data '%{public}@'", self,
                     [_jsonBuffer my_UTF8ToString]);
        _jsonBuffer = nil;
        _status = kTDStatusUpstreamError;
        return NO;
    }
    _jsonBuffer = nil;
    _document = document;
    return YES;
}

- (BOOL)registerAttachments
{
    NSDictionary* attachments = _document[@"_attachments"];
    if (attachments && ![attachments isKindOfClass:[NSDictionary class]]) {
        os_log_debug(CDTOSLog, "%{public}@: _attachments property is not a dictionary", self);
        return NO;
    }
    NSUInteger nAttachmentsInDoc = 0;
    for (NSString* attachmentName in attachments) {
        NSMutableDictionary* attachment = attachments[attachmentName];
        if ([attachment[@"follows"] isEqual:$true]) {
            // Check that each attachment in the JSON corresponds to an attachment MIME body.
            // Look up the attachment by either its MIME Content-Disposition header or MD5 digest:
            NSString* digest = attachment[@"digest"];
            TDBlobStoreWriter* writer = _attachmentsByName[attachmentName];
            if (writer) {
                // Identified the MIME body by the filename in its Disposition header:
                NSString* actualDigest = writer.MD5DigestString;
                if (digest && !$equal(digest, actualDigest) &&
                    !$equal(digest, writer.SHA1DigestString)) {
                    os_log_debug(CDTOSLog, "%{public}@: Attachment '%{public}@' has incorrect MD5 digest (%{public}@; should be %{public}@)", self, attachmentName, digest, actualDigest);
                    return NO;
                }
                attachment[@"digest"] = actualDigest;
            } else if (digest) {
                // Else look up the MIME body by its computed digest:
                writer = _attachmentsByDigest[digest];
                if (!writer) {
                    os_log_debug(CDTOSLog, "%{public}@: Attachment '%{public}@' does not appear in a MIME body", self, attachmentName);
                    return NO;
                }
            } else if (attachments.count == 1 && _attachmentsByDigest.count == 1) {
                // Else there's only one attachment, so just assume it matches & use it:
                writer = [_attachmentsByDigest allValues][0];
                attachment[@"digest"] = writer.MD5DigestString;
            } else {
                // No digest metatata, no filename in MIME body; give up:
                os_log_debug(CDTOSLog, "%{public}@: Attachment '%{public}@' has no digest metadata; cannot identify MIME body", self, attachmentName);
                return NO;
            }

            // Check that the length matches:
            NSNumber* lengthObj = attachment[@"encoded_length"] ?: attachment[@"length"];
            if (!lengthObj ||
                writer.length != [$castIf(NSNumber, lengthObj) unsignedLongLongValue]) {
                os_log_debug(CDTOSLog, "%{public}@: Attachment '%{public}@' has invalid length %{public}@ (should be %{public}llu)", self, attachmentName, lengthObj, writer.length);
                return NO;
            }

            ++nAttachmentsInDoc;
        }
    }
    if (nAttachmentsInDoc < _attachmentsByDigest.count) {
        os_log_debug(CDTOSLog, "%{public}@: More MIME bodies (%{public}u) than attachments (%{public}u)",
                     self, (unsigned)_attachmentsByDigest.count, (unsigned)nAttachmentsInDoc);
        return NO;
    }

    // If everything's copacetic, hand over the (uninstalled) blobs to the database to remember:
    [_database rememberAttachmentWritersForDigests:_attachmentsByDigest];
    return YES;
}

@end
