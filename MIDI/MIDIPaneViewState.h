/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * Everything the MIDI pane shows, computed in one place from the backend,
 * the user's selection and the last error. The controller renders a view
 * state and never decides on its own whether a button is enabled or what
 * the status line says, so the whole display logic is testable without
 * AppKit. Foundation only.
 */

#ifndef MIDIPANE_VIEW_STATE_H
#define MIDIPANE_VIEW_STATE_H

#import <Foundation/Foundation.h>
#import "MIDINetworkBackend.h"

/* Translates through the pane bundle's Localizable.strings. */
NSString *MIDIPaneLocalized(NSString *key);

/* What the user has selected, by identifier, so it survives the lists
   being rebuilt. */
@interface MIDIPaneSelection : NSObject <NSCopying>
@property (nonatomic, copy) NSString *sessionIdentifier;
@property (nonatomic, copy) NSString *hostIdentifier;
@property (nonatomic, copy) NSString *participantIdentifier;
@end

/* One table row. */
@interface MIDIPaneRow : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic) BOOL checked;
@end

@interface MIDIPaneViewState : NSObject

+ (instancetype)viewStateWithBackend:(id<MIDINetworkBackend>)backend
                           selection:(MIDIPaneSelection *)selection
                           lastError:(NSError *)lastError;

/* The selection after stale identifiers were dropped; a missing session
   selection falls back to the first session. */
@property (nonatomic, readonly) MIDIPaneSelection *selection;

@property (nonatomic, readonly) NSArray *sessionRows;
@property (nonatomic, readonly) NSInteger selectedSessionRow;     /* -1 = none */
@property (nonatomic, readonly) BOOL canAddSession;
@property (nonatomic, readonly) BOOL canRemoveSession;

@property (nonatomic, readonly) BOOL detailsEnabled;
@property (nonatomic, readonly) NSString *localName;
@property (nonatomic, readonly) NSString *advertisedName;
@property (nonatomic, readonly) NSString *portText;
@property (nonatomic, readonly) NSArray *policyTitles;
@property (nonatomic, readonly) NSInteger policyIndex;

@property (nonatomic, readonly) NSArray *directoryRows;
@property (nonatomic, readonly) NSInteger selectedHostRow;
@property (nonatomic, readonly) BOOL canAddHost;
@property (nonatomic, readonly) BOOL canRemoveHost;
@property (nonatomic, readonly) BOOL canConnect;

@property (nonatomic, readonly) NSArray *participantRows;
@property (nonatomic, readonly) NSInteger selectedParticipantRow;
@property (nonatomic, readonly) BOOL canDisconnect;

/* Pop-up items: "None" first, then the ports that fit the direction.
   The identifier arrays run parallel to the titles; NSNull for "None". */
@property (nonatomic, readonly) BOOL routingEnabled;
@property (nonatomic, readonly) NSArray *inputPortTitles;
@property (nonatomic, readonly) NSArray *inputPortIdentifiers;
@property (nonatomic, readonly) NSInteger inputPortIndex;
@property (nonatomic, readonly) NSArray *outputPortTitles;
@property (nonatomic, readonly) NSArray *outputPortIdentifiers;
@property (nonatomic, readonly) NSInteger outputPortIndex;

@property (nonatomic, readonly) NSString *statusText;
@property (nonatomic, readonly) BOOL statusIsError;

/* A new session for the + button: a free name and a free port. */
+ (MIDINetworkSession *)proposedSessionForBackend:(id<MIDINetworkBackend>)backend;

@end

#endif
