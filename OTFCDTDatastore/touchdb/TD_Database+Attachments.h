//
//  TD_Database+Attachments.h
//  TouchDB
//
//  Created by Jens Alfke on 1/18/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//
//  Modifications for this distribution by Cloudant, Inc., Copyright (c) 2014 Cloudant, Inc.
//

#import "TD_Database.h"
#import "CDTDefines.h"

#import "CDTBlobReader.h"

@class TDBlobStoreWriter, TDMultipartWriter, FMDatabase;



@interface TD_Database (Attachments)

/** Creates a TDBlobStoreWriter object that can be used to stream an attachment to the store. */
- (TDBlobStoreWriter *)attachmentWriter;

/** Creates TD_Attachment objects from the revision's '_attachments' property. */
- (NSDictionary *)attachmentsFromRevision:(TD_Revision *)rev
                               inDatabase:(FMDatabase *)db
                                   status:(TDStatus *)outStatus;

/** Given a newly-added revision, adds the necessary attachment rows to the database and stores
 * inline attachments into the blob store. */
- (TDStatus)processAttachments:(NSDictionary *)attachments
                   forRevision:(TD_Revision *)rev
            withParentSequence:(SequenceNumber)parentSequence
                    inDatabase:(FMDatabase *)db;

/** Constructs an "_attachments" dictionary for a revision, to be inserted in its JSON body. */
- (NSDictionary *)getAttachmentDictForSequence:(SequenceNumber)sequence
                                       options:(TDContentOptions)options
                                    inDatabase:(FMDatabase *)db;

/** Modifies a TD_Revision's _attachments dictionary by changing all attachments with revpos <
 * minRevPos into stubs; and if 'attachmentsFollow' is true, the remaining attachments will be
 * modified to _not_ be stubs but include a "follows" key instead of a body. */
+ (void)stubOutAttachmentsIn:(TD_Revision *)rev
                beforeRevPos:(int)minRevPos
           attachmentsFollow:(BOOL)attachmentsFollow;

/** Generates a MIME multipart writer for a revision, with separate body parts for each attachment
 * whose "follows" property is set. */
- (TDMultipartWriter *)multipartWriterForRevision:(TD_Revision *)rev
                                      contentType:(NSString *)contentType;

/** Returns the content and metadata of an attachment.
    If you pass NULL for the 'outEncoding' parameter, it signifies that you don't care about
   encodings and just want the 'real' data, so it'll be decoded for you. */
- (NSData *)getAttachmentForSequence:(SequenceNumber)sequence
                               named:(NSString *)filename
                                type:(NSString *__strong*)outType
                            encoding:(TDAttachmentEncoding *)outEncoding
                              status:(TDStatus *)outStatus;

/** Returns the blob for an attachment in the blob store. */
- (id<CDTBlobReader>)getAttachmentBlobForSequence:(SequenceNumber)sequence
                                            named:(NSString *)filename
                                             type:(NSString *__strong*)outType
                                         encoding:(TDAttachmentEncoding *)outEncoding
                                           status:(TDStatus *)outStatus;

/** Uses the "digest" field of the attachment dict to look up the attachment in the store and return
 * its blob. */
- (id<CDTBlobReader>)blobForAttachmentDict:(NSDictionary *)attachmentDict;

/** Deletes obsolete attachments from the database and blob store. */
- (TDStatus)garbageCollectAttachments:(FMDatabase *)db;

/** Updates or deletes an attachment, creating a new document revision in the process.
    Used by the PUT / DELETE methods called on attachment URLs. */
- (TD_Revision *)updateAttachment:(NSString *)filename
                             body:(TDBlobStoreWriter *)body
                             type:(NSString *)contentType
                         encoding:(TDAttachmentEncoding)encoding
                          ofDocID:(NSString *)docID
                            revID:(NSString *)oldRevID
                           status:(TDStatus *)outStatus
                       inDatabase:(FMDatabase *)db;
@end
