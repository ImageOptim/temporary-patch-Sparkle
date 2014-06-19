//
//  SUDiskImageUnarchiver.m
//  Sparkle
//
//  Created by Andy Matuschak on 6/16/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUDiskImageUnarchiver.h"
#import "SUUnarchiver_Private.h"
#import "NTSynchronousTask.h"
#import "SULog.h"
#include <CoreServices/CoreServices.h>

@implementation SUDiskImageUnarchiver

+ (BOOL)canUnarchivePath:(NSString *)path
{
	return [[path pathExtension] isEqualToString:@"dmg"];
}

// Called on a non-main thread.
- (void)extractDMG
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    [self extractDMGWithPassword:nil];
    
    [pool release];
}

// Called on a non-main thread.
- (void)extractDMGWithPassword:(NSString *)password
{
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
	BOOL mountedSuccessfully = NO;
	
	SULog(@"Extracting %@ as a DMG", archivePath);
	
	// get a unique mount point path
	NSString *mountPoint = nil;
	FSRef tmpRef;
	do
	{
		// Using NSUUID would make creating UUIDs be done in Cocoa,
		// and thus managed under ARC. Sadly, the class is in 10.8 and later.
		CFUUIDRef uuid = CFUUIDCreate(NULL);
		if (uuid)
		{
			CFStringRef uuidString = CFUUIDCreateString(NULL, uuid);
			if (uuidString)
			{
				mountPoint = [@"/Volumes" stringByAppendingPathComponent:(NSString*)uuidString];
				CFRelease(uuidString);
			}
			CFRelease(uuid);
		}
	}
	while (noErr == FSPathMakeRefWithOptions((UInt8 *)[mountPoint fileSystemRepresentation], kFSPathMakeRefDoNotFollowLeafSymlink, &tmpRef, NULL));

    NSData *promptData = nil;
    promptData = [NSData dataWithBytes:"yes\n" length:4];
	
    NSArray* arguments = @[@"attach", archivePath, @"-mountpoint", mountPoint, /*@"-noverify",*/ @"-nobrowse", @"-noautoopen"];
    
    NSData *output = nil;
	NSInteger taskResult = -1;
	@try
	{
		NTSynchronousTask* task = [[NTSynchronousTask alloc] init];
		
		[task run:@"/usr/bin/hdiutil" directory:@"/" withArgs:arguments input:promptData];
		
		taskResult = [task result];
		output = [[[task output] copy] autorelease];
        [task release];
	}
	@catch (NSException *localException)
	{ 
		goto reportError;
	}
	
	if (taskResult != 0)
	{
		NSString*	resultStr = output ? [[[NSString alloc] initWithData: output encoding: NSUTF8StringEncoding] autorelease] : nil;
        SULog( @"hdiutil failed with code: %d data: <<%@>>", taskResult, resultStr );
        goto reportError;
	}
	mountedSuccessfully = YES;
	
	// Now that we've mounted it, we need to copy out its contents.
	NSFileManager *manager = [[[NSFileManager alloc] init] autorelease];
	NSError *error = nil;
	NSArray *contents = [manager contentsOfDirectoryAtPath:mountPoint error:&error];
	if (error)
	{
		SULog(@"Couldn't enumerate contents of archive mounted at %@: %@", mountPoint, error);
		goto reportError;
	}
	
	for (NSString *item in contents)
	{
		NSString *fromPath = [mountPoint stringByAppendingPathComponent:item];
		NSString *toPath = [[archivePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:item];
		
		// We skip any files in the DMG which are not readable.
		if (![manager isReadableFileAtPath:fromPath]) {
			continue;
		}
		
		SULog(@"copyItemAtPath:%@ toPath:%@", fromPath, toPath);
		
		if (![manager copyItemAtPath:fromPath toPath:toPath error:&error])
		{
			SULog(@"Couldn't copy item: %@ : %@", error, error.userInfo ? error.userInfo : @"");
			goto reportError;
		}
	}
	
	[self performSelectorOnMainThread:@selector(notifyDelegateOfSuccess) withObject:nil waitUntilDone:NO];
	goto finally;
	
reportError:
	[self performSelectorOnMainThread:@selector(notifyDelegateOfFailure) withObject:nil waitUntilDone:NO];

finally:
	if (mountedSuccessfully)
		[NSTask launchedTaskWithLaunchPath:@"/usr/bin/hdiutil" arguments:@[@"detach", mountPoint, @"-force"]];
	else
		SULog(@"Can't mount DMG %@",archivePath);
	[pool drain];
}

- (void)start
{
	[NSThread detachNewThreadSelector:@selector(extractDMG) toTarget:self withObject:nil];
}

+ (void)load
{
	[self registerImplementation:self];
}

- (BOOL)isEncrypted:(NSData*)resultData
{
	BOOL result = NO;
	if(resultData)
	{
		NSString *data = [[[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding] autorelease];
        
        if ((data != nil) && !NSEqualRanges([data rangeOfString:@"passphrase-count"], NSMakeRange(NSNotFound, 0)))
		{
			result = YES;
		}
	}
	return result;
}

@end
