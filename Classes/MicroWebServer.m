/*
 * MicroWebServer.m
 * Created by Benjamin Ragheb on 4/29/08.
 * Copyright 2015 Heroic Software Inc
 *
 * This file is part of FatWatch.
 *
 * FatWatch is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * FatWatch is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with FatWatch.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "MicroWebServer.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>


@interface MicroWebConnection ()
- (id)initWithServer:(MicroWebServer *)server readStream:(CFReadStreamRef)readStream writeStream:(CFWriteStreamRef)writeStream;
- (void)readStreamHasBytesAvailable;
- (void)writeStreamCanAcceptBytes;
@end


void MicroReadStreamCallback(CFReadStreamRef stream, CFStreamEventType eventType, void *info) {
	MicroWebConnection *connection = (__bridge MicroWebConnection *)info;
	switch (eventType) {
		case kCFStreamEventHasBytesAvailable:
			[connection readStreamHasBytesAvailable];
			break;
		default:
			NSLog(@"WARNING: Unhandled read stream event %lu", eventType);
			break;
	}
}


void MicroWriteStreamCallback(CFWriteStreamRef stream, CFStreamEventType eventType, void *info) {
	MicroWebConnection *connection = (__bridge MicroWebConnection *)info;
	switch (eventType) {
		case kCFStreamEventCanAcceptBytes:
			[connection writeStreamCanAcceptBytes];
			break;
		default:
			NSLog(@"WARNING: Unhandled write stream event %lu", eventType);
			break;
	}
}


void MicroSocketCallback(CFSocketRef s, CFSocketCallBackType callbackType, CFDataRef address, const void *data, void *info) {
	if (callbackType != kCFSocketAcceptCallBack) return;
	
	CFSocketNativeHandle *nativeHandle = (CFSocketNativeHandle *)data;
	CFReadStreamRef readStream;
	CFWriteStreamRef writeStream;
	CFStreamCreatePairWithSocket(kCFAllocatorDefault, *nativeHandle, &readStream, &writeStream);
	CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
	CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);

	MicroWebServer *webServer = (__bridge MicroWebServer *)info;
	MicroWebConnection *webConnection;
	
	webConnection = [[MicroWebConnection alloc] initWithServer:webServer
													readStream:readStream 
												   writeStream:writeStream];
	
    if ([webServer.delegate respondsToSelector:@selector(webConnectionWillReceiveRequest:)]) {
        [webServer.delegate webConnectionWillReceiveRequest:webConnection];
    }
	
	CFStreamClientContext context;
	context.version = 0;
	context.info = (__bridge void *)(webConnection);
	context.retain = NULL;
	context.release = NULL;
	context.copyDescription = NULL;
	
	CFReadStreamSetClient(readStream, 
						  kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred,
						  &MicroReadStreamCallback,
						  &context);
	
	CFWriteStreamSetClient(writeStream,
						   kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred,
						   &MicroWriteStreamCallback, 
						   &context);

	CFReadStreamScheduleWithRunLoop(readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
	CFWriteStreamScheduleWithRunLoop(writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

	CFReadStreamOpen(readStream);
}


@implementation MicroWebServer
{
	NSString *name;
	CFSocketRef listenSocket;
	NSNetService *netService;
	id <MicroWebServerDelegate> __weak delegate;
	BOOL running;
}

@synthesize delegate;
@synthesize name;
@synthesize running;


- (CFSocketRef)newSocketForPort:(in_port_t)port {
	CFSocketContext context;
	context.version = 0;
	context.info = (__bridge void *)(self);
	context.retain = NULL;
	context.release = NULL;
	context.copyDescription = NULL;
	
	CFSocketRef theSocket = CFSocketCreate(kCFAllocatorDefault, 
										   PF_INET, 
										   SOCK_STREAM, 
										   IPPROTO_TCP, 
										   kCFSocketAcceptCallBack, 
										   &MicroSocketCallback,
										   &context);
	if (theSocket == NULL) return NULL;
	
	CFRunLoopSourceRef runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, theSocket, 0);
	if (runLoopSource == NULL) {
		CFRelease(theSocket);
		return NULL;
	}
	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
	CFRelease(runLoopSource);
	
	struct sockaddr_in addr4;
	memset(&addr4, 0, sizeof(addr4));
	addr4.sin_len = sizeof(addr4);
	addr4.sin_family = AF_INET;
	addr4.sin_port = htons(port);
	addr4.sin_addr.s_addr = htonl(INADDR_ANY);
	
	// Wrap the native address structure for CFSocketCreate.
	CFDataRef addressData = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, (const UInt8*)&addr4, sizeof(addr4), kCFAllocatorNull);
	if (addressData == NULL) {
		CFRelease(theSocket);
		return NULL;
	}
	
	CFSocketError err;
	
	// Set the local binding which causes the socket to start listening.
	err = CFSocketSetAddress(theSocket, addressData);
	CFRelease(addressData);
	if (err != kCFSocketSuccess) {
		CFRelease(theSocket);
		return NULL;
	}
	
	return theSocket;
}


- (UInt16)port {
	if (listenSocket == NULL) return 0;
	struct sockaddr_in address;
	CFDataRef addressData = CFSocketCopyAddress(listenSocket);
	CFDataGetBytes(addressData, CFRangeMake(0, sizeof(address)), (UInt8 *)&address);
	CFRelease(addressData);
	return ntohs(address.sin_port);
}


- (NSURL *)rootURL {
	if (listenSocket == NULL) return nil;

	struct ifaddrs *ifa = NULL, *ifList, *ifBest = NULL;
	
	int err = getifaddrs(&ifList);
	if (err < 0) return nil;
	
	for (ifa = ifList; ifa != NULL; ifa = ifa->ifa_next) {
		if (ifa->ifa_addr == NULL) continue;
		if (ifa->ifa_addr->sa_family != AF_INET) continue; // skip non-IP4
		ifBest = ifa;
		// Stop searching unless this is just a loopback address
		if (strncmp(ifa->ifa_name, "lo", 2) != 0) break;
	}
	
	NSURL *theURL = nil;
	
	if (ifBest) {
		struct sockaddr_in *address = (struct sockaddr_in *)ifBest->ifa_addr;
		char *host = inet_ntoa(address->sin_addr);
		NSString *string = [NSString stringWithFormat:@"http://%s:%d", host, self.port];
		theURL = [NSURL URLWithString:string];
	}
	
	freeifaddrs(ifList);
	
	return theURL;
}


- (void)start {
	NSAssert(delegate != nil, @"must set delegate");
	NSAssert([delegate respondsToSelector:@selector(handleWebConnection:)], @"delegate must implement handleWebConnection:");
	
	if (running) return; // ignore if already running
			
	listenSocket = [self newSocketForPort:1234];
	if (listenSocket == NULL) {
        listenSocket = [self newSocketForPort:INADDR_ANY];
    }
	if (listenSocket == NULL) return;

	running = YES;
	
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"MWSPublishNetService"]) {
		netService = [[NSNetService alloc] initWithDomain:@"" 
													 type:@"_http._tcp."
													 name:self.name
													 port:self.port];
		[netService setDelegate:self];
		[netService publish];
	}
}


- (void)stop {
	if (!running) return; // ignore if already stopped
	[netService stop];
	netService = nil;
	if (listenSocket != NULL) {
		CFSocketInvalidate(listenSocket);
		CFRelease(listenSocket);
		listenSocket = NULL;
	}
	running = NO;
}


#pragma mark NSNetServiceDelegate


- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict {
	NSLog(@"Did not publish service: %@", errorDict);
}


#pragma mark Cleanup


- (void)dealloc {
	[self stop];
}


@end


@implementation MicroWebConnection
{
	MicroWebServer *webServer;
	CFReadStreamRef readStream;
	CFWriteStreamRef writeStream;
	CFHTTPMessageRef requestMessage;
	CFHTTPMessageRef responseMessage;
	CFDataRef responseData;
	CFIndex responseBytesRemaining;
	NSArray *httpDateFormatterArray;
}

- (id)initWithServer:(MicroWebServer *)server readStream:(CFReadStreamRef)newReadStream writeStream:(CFWriteStreamRef)newWriteStream {
	if ((self = [super init])) {
		webServer = server;
		readStream = newReadStream;
		writeStream = newWriteStream;
		requestMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, YES);
	}
	return self;
}


- (void)dealloc {
	if (responseData) CFRelease(responseData);
	if (responseMessage) CFRelease(responseMessage);
	CFRelease(requestMessage);
	CFRelease(writeStream);
	CFRelease(readStream);
}


- (NSString *)description {
	if (responseData) {
		return [NSString stringWithFormat:@"MicroWebConnection<%p> (%ld/%ld response bytes remain)", self, responseBytesRemaining, CFDataGetLength(responseData)];
	} else {
		return [NSString stringWithFormat:@"MicroWebConnection<%p>: reading", self];
	}
}


- (BOOL)readAvailableBytes {
	const CFIndex bufferCapacity = 512;
	UInt8 buffer[bufferCapacity];

	do {
		CFIndex dataLength = CFReadStreamRead(readStream, buffer, bufferCapacity);
		
		if (dataLength > 0) {
			Boolean didSucceed = CFHTTPMessageAppendBytes(requestMessage, buffer, dataLength);
			if (! didSucceed) {
				NSLog(@"CFHTTPMessageAppendBytes: returned false");
				return YES;
			}
		} else if (dataLength == 0) {
			return YES; // end of stream
		} else {
			NSLog(@"CFReadStreamRead: returned %ld", dataLength);
			return YES;
		}
	} while (CFReadStreamHasBytesAvailable(readStream));
	
	return NO;
}


- (BOOL)isRequestComplete {
	if (! CFHTTPMessageIsHeaderComplete(requestMessage)) return NO;
	
//	NSString *transferEncodingStr = [self stringForRequestHeader:@"Transfer-Encoding"];
//	if (transferEncodingStr) {
//		NSLog(@"transfer-encoding: %@", transferEncodingStr);
//	}
	
	NSString *contentLengthStr = [self stringForRequestHeader:@"Content-Length"];
	NSUInteger contentLength = [contentLengthStr integerValue];
	if (contentLength > 0) {
		NSData *bodyData = [self requestBodyData];
//		NSLog(@"content length is %d and we got %d", contentLength, [bodyData length]);
		return [bodyData length] >= contentLength;
	}
	
	return YES; // for all we know, anyway
}


- (void)readStreamHasBytesAvailable {
	BOOL shouldClose = [self readAvailableBytes];

	if ([self isRequestComplete]) {
        if ([webServer.delegate respondsToSelector:@selector(webConnectionDidReceiveRequest:)]) {
            [webServer.delegate webConnectionDidReceiveRequest:self];
        }
		[(id)webServer.delegate performSelector:@selector(handleWebConnection:) withObject:self afterDelay:0];
		shouldClose = YES;
	}

	if (shouldClose) {
		CFReadStreamClose(readStream);
	}
}


- (void)writeStreamCanAcceptBytes {
	if (responseBytesRemaining == 0) {
		CFWriteStreamClose(writeStream);
        if ([webServer.delegate respondsToSelector:@selector(webConnectionDidSendResponse:)]) {
            [webServer.delegate webConnectionDidSendResponse:self];
        }
		return;
	}
	
	const UInt8 *buffer = CFDataGetBytePtr(responseData);
	CFIndex bufferLength = CFDataGetLength(responseData);
	
	buffer += (bufferLength - responseBytesRemaining);
	CFIndex bytesWritten = CFWriteStreamWrite(writeStream, buffer, responseBytesRemaining);
	if (bytesWritten < 0) {
		NSLog(@"CFWriteStreamWrite: returned %ld", bytesWritten);
		return;
	}
	responseBytesRemaining -= bytesWritten;
}


- (NSDateFormatter *)httpDateFormatter {
	// Thanks http://blog.mro.name/2009/08/nsdateformatter-http-header/
	if (httpDateFormatterArray == nil) {
		NSTimeZone *timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
		NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
		
		NSDateFormatter *rfc1123 = [[NSDateFormatter alloc] init];
		rfc1123.timeZone = timeZone;
		rfc1123.locale = locale;
		rfc1123.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
		
		NSDateFormatter *rfc850 = [[NSDateFormatter alloc] init];
		rfc850.timeZone = timeZone;
		rfc850.locale = locale;
		rfc850.dateFormat = @"EEEE',' dd'-'MMM'-'yy HH':'mm':'ss z";
		
		NSDateFormatter *atime = [[NSDateFormatter alloc] init];
		atime.timeZone = timeZone;
		atime.locale = locale;
		atime.dateFormat = @"EEE MMM d HH':'mm':'ss yyyy";
		
		httpDateFormatterArray = [[NSArray alloc] initWithObjects:rfc1123, rfc850, atime, nil];
		
	}
	return httpDateFormatterArray[0];
}


- (NSString *)requestMethod {
	NSString *method = (NSString *)CFBridgingRelease(CFHTTPMessageCopyRequestMethod(requestMessage));
	return method;
}


- (NSURL *)requestURL {
	NSURL *url = (NSURL *)CFBridgingRelease(CFHTTPMessageCopyRequestURL(requestMessage));
	return url;
}


- (NSDictionary *)requestHeaders {
	NSDictionary *headers = (NSDictionary *)CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(requestMessage));
	return headers;
}


- (NSString *)stringForRequestHeader:(NSString *)headerName {
	NSString *headerValue = (NSString *)CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(requestMessage, (__bridge CFStringRef)headerName));
	return headerValue;
}


- (NSDate *)dateForRequestHeader:(NSString *)headerName {
	NSString *string = [self stringForRequestHeader:headerName];
	if (string == nil) return nil;
	[self httpDateFormatter];
	for (NSDateFormatter *df in httpDateFormatterArray) {
		NSDate *date = [df dateFromString:string];
		if (date) return date;
	}
	return nil;
}


- (NSData *)requestBodyData {
	NSData *data = (NSData *)CFBridgingRelease(CFHTTPMessageCopyBody(requestMessage));
	return data;
}


- (void)beginResponseWithStatus:(CFIndex)statusCode {
	responseMessage = CFHTTPMessageCreateResponse(kCFAllocatorDefault, statusCode, NULL, kCFHTTPVersion1_1);
}


- (void)setValue:(id)value forResponseHeader:(NSString *)header {
	NSAssert(responseMessage != nil, @"must call beginResponseWithStatus: first");
	NSString *string;
	
	if ([value isKindOfClass:[NSDate class]]) {
		string = [[self httpDateFormatter] stringFromDate:value];
	}
	else {
		string = [value description];
	}
	
	CFHTTPMessageSetHeaderFieldValue(responseMessage, (__bridge CFStringRef)header, (__bridge CFStringRef)string);
}


- (void)endResponseWithBodyString:(NSString *)string {
	NSAssert(responseMessage != nil, @"must call beginResponseWithStatus: first");
	[self endResponseWithBodyData:[string dataUsingEncoding:NSUTF8StringEncoding]];
}


- (void)endResponseWithBodyData:(NSData *)data {
	NSAssert(responseMessage != nil, @"must call beginResponseWithStatus: first");
	CFHTTPMessageSetBody(responseMessage, (__bridge CFDataRef)data);

	NSString *lenstr = [NSString stringWithFormat:@"%lu", (unsigned long)[data length]];
	CFHTTPMessageSetHeaderFieldValue(responseMessage, CFSTR("Content-Length"), (__bridge CFStringRef)lenstr);
	
	// Sorry, we don't support Keep Alive.
	CFHTTPMessageSetHeaderFieldValue(responseMessage, CFSTR("Connection"), CFSTR("close"));
	
    if ([webServer.delegate respondsToSelector:@selector(webConnectionWillSendResponse:)]) {
        [webServer.delegate webConnectionWillSendResponse:self];
    }

	responseData = CFHTTPMessageCopySerializedMessage(responseMessage);
	CFRelease(responseMessage); responseMessage = NULL;
	
	responseBytesRemaining = CFDataGetLength(responseData);
	CFWriteStreamOpen(writeStream);
}


- (void)respondWithErrorMessage:(NSString *)message {
	[self beginResponseWithStatus:500];
	[self setValue:@"text/plain; charset=utf-8" forResponseHeader:@"Content-Type"];
	[self endResponseWithBodyString:message];
}


- (void)respondWithRedirectToURL:(NSURL *)url {
	[self beginResponseWithStatus:301];
	[self setValue:[url absoluteString] forResponseHeader:@"Location"];
	[self endResponseWithBodyData:[NSData data]];
}


- (void)respondWithRedirectToPath:(NSString *)path {
    NSURL *rootURL;
    
    NSString *host = [self stringForRequestHeader:@"Host"];
    if (host) {
        rootURL = [NSURL URLWithString:[@"http://" stringByAppendingString:host]];
    } else {
        rootURL = [webServer rootURL];
    }
    
	NSAssert(rootURL, @"Must have a root URL");
	NSURL *url = [NSURL URLWithString:path relativeToURL:rootURL];
	[self respondWithRedirectToURL:url];
}


@end
