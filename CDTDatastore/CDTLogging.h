//
//  CDTLogging.h
//  CloudantSync
//
//
//  Created by Rhys Short on 01/10/2014.
//  Copyright (c) 2014 Cloudant. All rights reserved.
//
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <CocoaLumberjack/CocoaLumberjack.h>
#import <os/log.h>

#ifndef _CDTLogging_h
#define _CDTLogging_h

/*

 Macro definitions for custom logger contexts, this allows different parts of CDTDatastore
 to separate its log messages and have different levels.

 Each component should set its log level using a static variable in the name <component>LogLevel
 the macros will then perform correctly at compile time.

 */


#define CDTOSLog os_log_create(NSBundle.mainBundle.bundleIdentifier.UTF8String, @"CDTOSLog".UTF8String)


#endif
