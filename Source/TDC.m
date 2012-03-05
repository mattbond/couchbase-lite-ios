//
//  TDC.m
//  TouchDB
//
//  Created by Jens Alfke on 3/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "TDC.h"
#import "TDBody.h"
#import "TDRouter.h"
#import "TDServer.h"
#import "Test.h"
#import <string.h>


static NSString* sServerDir;
static TDServer* sServer;


static NSString* CToNSString(const char* str) {
    return [[[NSString alloc] initWithCString: str encoding: NSUTF8StringEncoding] autorelease];
}


static void FreeStringList(unsigned count, const char** stringList) {
    if (!stringList)
        return;
    for (unsigned i = 0; i < count; ++i)
        free((char*)stringList[i]);
    free(stringList);
}


static const char** CopyStringList(unsigned count, const char** stringList) {
    if (count == 0)
        return NULL;
    const char** output = (const char**) malloc(count * sizeof(const char*));
    if (!output)
        return NULL;
    for (unsigned i = 0; i < count; ++i) {
        output[i] = strdup(stringList[i]);
        if (!output[i]) {
            FreeStringList(i, output);
            return NULL;
        }
    }
    return output;
}


TDCMIME* TDCMIMECreate(unsigned headerCount,
                       const char** headerNames,
                       const char** headerValues,
                       size_t contentLength,
                       const void* content,
                       bool copyContent)
{
    TDCMIME* mime = calloc(sizeof(TDCMIME), 1);  // initialized to all 0 for safety
    if (!mime)
        goto fail;
    if (headerCount > 0) {
        mime->headerCount = headerCount;
        mime->headerNames = CopyStringList(headerCount, headerNames);
        mime->headerValues = CopyStringList(headerCount, headerValues);
        if (!mime->headerNames || !mime->headerValues)
            goto fail;
    }
    if (contentLength > 0) {
        mime->contentLength = contentLength;
        if (copyContent) {
            mime->content = malloc(contentLength);
            if (!mime->content)
                goto fail;
            memcpy((void*)mime->content, content, contentLength);
        } else {
            mime->content = content;
        }
    }
    return mime;
    
fail:
    TDCMIMEFree(mime);
    return NULL;
}


void TDCMIMEFree(TDCMIME* mime) {
    if (!mime)
        return;
    FreeStringList(mime->headerCount, mime->headerNames);
    FreeStringList(mime->headerCount, mime->headerValues);
    free((void*)mime->content);
    free(mime);
}


void TDCSetBaseDirectory(const char* path) {
    assert(!sServerDir);
    sServerDir = [CToNSString(path) retain];
}


static NSURLRequest* CreateRequest(NSString* method, 
                                   NSString* urlStr,
                                   TDCMIME* headersAndBody)
{
    NSURL* url = urlStr ? [NSURL URLWithString: urlStr] : nil;
    if (!url) {
        Warn(@"Invalid URL <%@>", urlStr);
        return nil;
    }
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url];
    request.HTTPMethod = method;
    if (headersAndBody) {
        for (unsigned i = 0; i < headersAndBody->headerCount; ++i) {
            NSString* header = CToNSString(headersAndBody->headerNames[i]);
            NSString* value = CToNSString(headersAndBody->headerValues[i]);
            if (!header || !value) {
                Warn(@"Invalid request headers");
                return nil;
            }
            [request setValue: value forHTTPHeaderField: header];
        }
        
        if (headersAndBody->content) {
            request.HTTPBody = [NSData dataWithBytesNoCopy: (void*)headersAndBody->content
                                                    length: headersAndBody->contentLength];
            headersAndBody->content = NULL;  // prevent double free
        }
    }
    return request;
}


static TDCMIME* CreateMIMEFromTDResponse(TDResponse* response) {
    NSDictionary* headers = response.headers;
    NSArray* headerNames = headers.allKeys;
    unsigned headerCount = headers.count;
    const char* cHeaderNames[headerCount], *cHeaderValues[headerCount];
    for (unsigned i = 0; i < headerCount; ++i) {
        NSString* name = [headerNames objectAtIndex: i];
        cHeaderNames[i] = [name UTF8String];
        cHeaderValues[i] = [[headers objectForKey: name] UTF8String];
    }
    NSData* content = response.body.asJSON;
    return TDCMIMECreate(headerCount, cHeaderNames, cHeaderValues,
                         content.length, content.bytes, YES);
}


int TDCSendRequest(const char* method,
                   const char* url,
                   TDCMIME* headersAndBody,
                   TDCMIME** outResponse)
{
    @autoreleasepool {
        *outResponse = NULL;
        
        // Create TDServer on first call:
        if (!sServer) {
            assert(sServerDir);
            NSError* error;
            sServer = [[TDServer alloc] initWithDirectory: sServerDir error: &error];
            if (!sServer) {
                Warn(@"Unable to create TouchDB server: %@", error);
                TDCMIMEFree(headersAndBody);
                return 500;
            }
        }
        
        // Create an NSURLRequest:
        NSURLRequest* request = CreateRequest(CToNSString(method),
                                              CToNSString(url),
                                              headersAndBody);
        TDCMIMEFree(headersAndBody);
        if (!request)
            return 400;
        
        // Create & run the router:
        TDRouter* router = [[[TDRouter alloc] initWithServer: sServer
                                                     request: request] autorelease];
        __block bool finished = false;
        router.onFinished = ^{finished = true;};
        [router start];
        while (!finished) {
            if (![[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                          beforeDate: [NSDate dateWithTimeIntervalSinceNow: 5]])
                  break;
        }
        
        // Return the response:
        *outResponse = CreateMIMEFromTDResponse(router.response);
        return router.response.status;
    }
}



TestCase(TDCSendRequest) {
    TDCSetBaseDirectory("/tmp/TDCTest");
    
    TDCMIME* response;
    int status = TDCSendRequest("GET", "touchdb:///", NULL, &response);
    CAssertEq(status, 200);
    
    NSString* body = [[[NSString alloc] initWithData: [NSData dataWithBytes: response->content
                                                                     length: response->contentLength]
                                            encoding: NSUTF8StringEncoding] autorelease];
    Log(@"Response body = '%@'", body);
    CAssert([body rangeOfString: @"TouchDB"].length > 0);
    bool gotContentType=false, gotServer=false;
    for (unsigned i = 0; i < response->headerCount; ++i) {
        Log(@"Header #%d: %s = %s", i+1, response->headerNames[i], response->headerValues[i]);
        if (strcmp(response->headerNames[i], "Content-Type") == 0) {
            gotContentType = true;
            CAssert(strcmp(response->headerValues[i], "application/json") == 0);
        } else if (strcmp(response->headerNames[i], "Server") == 0) {
            gotServer = true;
            CAssert(strncmp(response->headerValues[i], "TouchDB", 7) == 0);
        }
    }
    CAssert(gotContentType);
    CAssert(gotServer);
    TDCMIMEFree(response);
}
