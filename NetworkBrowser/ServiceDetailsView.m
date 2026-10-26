/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import "ServiceDetailsView.h"
#import "TXTRecordFormatter.h"

@implementation ServiceDetailsView

- (id)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame: frame];
  if (self)
    {
      currentService = nil;
      
      /* Create scroll view */
      scrollView = [[NSScrollView alloc] initWithFrame: frame];
      [scrollView setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
      [scrollView setHasVerticalScroller: YES];
      [scrollView setHasHorizontalScroller: NO];
      [scrollView setBorderType: NSBezelBorder];
      
      /* Create text view */
      NSRect textFrame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
      textView = [[NSTextView alloc] initWithFrame: textFrame];
      [textView setEditable: NO];
      [textView setSelectable: YES];
      [textView setHorizontallyResizable: NO];
      [textView setVerticallyResizable: YES];
      [textView setMinSize: NSMakeSize(0, 0)];
      [textView setMaxSize: NSMakeSize(1e7, 1e7)];
      [[textView textContainer] setContainerSize: 
        NSMakeSize(frame.size.width, 1e7)];
      [[textView textContainer] setWidthTracksTextView: YES];
      
      [scrollView setDocumentView: textView];
      [self addSubview: scrollView];
    }
  return self;
}

- (void)dealloc
{
  RELEASE(scrollView);
  RELEASE(textView);
  RELEASE(currentService);
  [super dealloc];
}

- (void)displayService:(NSNetService *)service
{
  NSMutableString *details = [NSMutableString string];
  
  ASSIGN(currentService, service);
  
  [details appendFormat: @"Service Name: %@\n\n", [service name]];
  [details appendFormat: @"Type: %@\n", [service type]];
  [details appendFormat: @"Domain: %@\n\n", [service domain]];
  
  /* Resolve the service to get addresses and port */
  if ([service addresses] && [[service addresses] count] > 0)
    {
      [details appendFormat: @"Port: %ld\n\n", (long)[service port]];
      [details appendString: @"Addresses:\n"];
      
      for (NSData *addressData in [service addresses])
        {
          struct sockaddr *sa = (struct sockaddr *)[addressData bytes];
          char addr_str[INET6_ADDRSTRLEN];
          
          if (sa->sa_family == AF_INET)
            {
              struct sockaddr_in *sin = (struct sockaddr_in *)sa;
              inet_ntop(AF_INET, &sin->sin_addr, addr_str, INET6_ADDRSTRLEN);
              [details appendFormat: @"  %s\n", addr_str];
            }
          else if (sa->sa_family == AF_INET6)
            {
              struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)sa;
              inet_ntop(AF_INET6, &sin6->sin6_addr, addr_str, INET6_ADDRSTRLEN);
              [details appendFormat: @"  [%s]\n", addr_str];
            }
        }
      [details appendString: @"\n"];
    }
  else
    {
      [details appendString: @"(Service not yet resolved)\n\n"];
    }
  
  /* Host name */
  [details appendFormat: @"Host Name: %@\n\n", [service hostName]];
  
  /* Properties */
  NSDictionary *dict = [NSNetService dictionaryFromTXTRecordData: [service TXTRecordData]];
  NSString *propertyLines = [TXTRecordFormatter linesForTXTDictionary: dict];
  if (propertyLines)
    {
      [details appendString: @"Properties:\n"];
      [details appendString: propertyLines];
    }

  [textView setString: details];
}

- (void)clear
{
  if (currentService != nil)
    {
      RELEASE(currentService);
      currentService = nil;
    }
  [textView setString: @""];
}

@end
