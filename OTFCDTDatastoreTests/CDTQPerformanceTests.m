//
//  CloudantQueryObjcTests.m
//  CloudantQueryObjcTests
//
//  Created by Michael Rhodes on 09/27/2014.
//  Copyright (c) 2014 Michael Rhodes. All rights reserved.
//
#import <OTFCDTDatastore/CDTQIndexCreator.h>
#import <OTFCDTDatastore/CDTQIndexManager.h>
#import <OTFCDTDatastore/CDTQIndexUpdater.h>
#import <OTFCDTDatastore/CDTQQueryExecutor.h>
#import <OTFCDTDatastore/CDTQResultSet.h>
#import <OTFCDTDatastore/CloudantSync.h>
#import <Expecta/Expecta.h>
#import <Specta/Specta.h>


SpecBegin(CDTQPerformance)

    xdescribe(@"CDTQ Performance", ^{

        __block NSString *factoryPath;
        __block CDTDatastoreManager *factory;

        beforeAll(^{

            // Create a new CDTDatastoreFactory at a temp path

            NSString *tempDirectoryTemplate = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"cloudant_sync_ios_tests.XXXXXX"];
            const char *tempDirectoryTemplateCString =
                [tempDirectoryTemplate fileSystemRepresentation];
            char *tempDirectoryNameCString =
                (char *)malloc(strlen(tempDirectoryTemplateCString) + 1);
            strcpy(tempDirectoryNameCString, tempDirectoryTemplateCString);

            char *result = mkdtemp(tempDirectoryNameCString);
            expect(result).to.beTruthy();

            factoryPath = [[NSFileManager defaultManager]
                stringWithFileSystemRepresentation:tempDirectoryNameCString
                                            length:strlen(result)];
            free(tempDirectoryNameCString);

            NSError *error;
            factory = [[CDTDatastoreManager alloc] initWithDirectory:factoryPath error:&error];

            //
            // Create databases with 1k, 10k, 50k, 100k docs for tests
            //

            CDTDocumentRevision *rev;

            CDTDatastore *ds1k = [factory datastoreNamed:@"test1k" error:nil];
            CDTDatastore *ds10k = [factory datastoreNamed:@"test10k" error:nil];
            CDTDatastore *ds50k = [factory datastoreNamed:@"test50k" error:nil];
            CDTDatastore *ds100k = [factory datastoreNamed:@"test100k" error:nil];
            for (int i = 0; i < 100000; i++) {
                
                @autoreleasepool {
                    rev = [CDTDocumentRevision
                        revisionWithDocId:[NSString stringWithFormat:@"doc-%d", i]];
                    rev.body =
                        [@{ @"name" : @"mike",
                            @"age" : @34,
                            @"docNumber" : @(i),
                            @"pet" : @"cat" } mutableCopy];

                if (i < 1000) {
                    [ds1k createDocumentFromRevision:rev error:nil];
                }

                if (i < 10000) {
                    [ds10k createDocumentFromRevision:rev error:nil];
                }

                if (i < 50000) {
                    [ds50k createDocumentFromRevision:rev error:nil];
                }

                [ds100k createDocumentFromRevision:rev error:nil];
                    
                }
            }
        });

        afterAll(^{
            // Delete the databases we used
            factory = nil;
            NSError *error;
            [[NSFileManager defaultManager] removeItemAtPath:factoryPath error:&error];
        });

        it(@"create datastores", ^{// this test is just here to make beforeAll create
                                   // its databases before starting the real tests.
           });

        context(@"1k docs", ^{
            __block CDTQIndexManager *im;
            beforeEach(^{
                CDTDatastore *ds = [factory datastoreNamed:@"test1k" error:nil];
                im = [CDTQIndexManager managerUsingDatastore:ds error:nil];
                expect(im).toNot.beNil();
            });

            it(@"one field",
               ^{ expect([im ensureIndexed:@[ @"name" ] withName:@"pet1"]).toNot.beNil(); });

            it(@"three field", ^{
                expect([im ensureIndexed:@[ @"name", @"age", @"pet" ] withName:@"pet2"])
                    .toNot.beNil();
            });
        });

        context(@"10k docs", ^{
            __block CDTQIndexManager *im;
            beforeEach(^{
                CDTDatastore *ds = [factory datastoreNamed:@"test10k" error:nil];
                im = [CDTQIndexManager managerUsingDatastore:ds error:nil];
                expect(im).toNot.beNil();
            });

            it(@"one field",
               ^{ expect([im ensureIndexed:@[ @"name" ] withName:@"pet1"]).toNot.beNil(); });

            it(@"three field", ^{
                expect([im ensureIndexed:@[ @"name", @"age", @"pet" ] withName:@"pet2"])
                    .toNot.beNil();
            });
        });

        context(@"50k docs", ^{
            __block CDTQIndexManager *im;
            beforeEach(^{
                CDTDatastore *ds = [factory datastoreNamed:@"test50k" error:nil];
                im = [CDTQIndexManager managerUsingDatastore:ds error:nil];
                expect(im).toNot.beNil();
            });

            it(@"one field",
               ^{ expect([im ensureIndexed:@[ @"name" ] withName:@"pet1"]).toNot.beNil(); });

            it(@"three field", ^{
                expect([im ensureIndexed:@[ @"name", @"age", @"pet" ] withName:@"pet2"])
                    .toNot.beNil();
            });
        });

        context(@"100k docs", ^{
            __block CDTQIndexManager *im;
            beforeEach(^{
                CDTDatastore *ds = [factory datastoreNamed:@"test100k" error:nil];
                im = [CDTQIndexManager managerUsingDatastore:ds error:nil];
                expect(im).toNot.beNil();
            });

            it(@"one field",
               ^{ expect([im ensureIndexed:@[ @"name" ] withName:@"pet1"]).toNot.beNil(); });

            it(@"three field", ^{
                expect([im ensureIndexed:@[ @"name", @"age", @"pet" ] withName:@"pet2"])
                    .toNot.beNil();
            });
        });

    });

SpecEnd
