/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMLocalSession.h"
#import "GMSessionMessage.h"
#import "GMRTPMIDI.h"
#import "GMSocketAddress.h"

GMConnectionPolicy GMConnectionPolicyFromString(NSString *s, BOOL *valid)
{
  if (valid) *valid = YES;
  if ([s isEqualToString: @"anyone"]) return GMConnectionPolicyAnyone;
  if ([s isEqualToString: @"directory"]) return GMConnectionPolicyDirectory;
  if ([s isEqualToString: @"nobody"]) return GMConnectionPolicyNobody;
  if (valid) *valid = NO;
  return GMConnectionPolicyNobody;
}

NSString *GMConnectionPolicyString(GMConnectionPolicy p)
{
  switch (p)
    {
      case GMConnectionPolicyAnyone: return @"anyone";
      case GMConnectionPolicyDirectory: return @"directory";
      case GMConnectionPolicyNobody: return @"nobody";
    }
  return @"nobody";
}

@implementation GMLocalSession
{
  NSMutableArray *_peers;
  NSTimeInterval _epoch;
}

- (instancetype) initWithName: (NSString *)name
                         port: (uint16_t)controlPort
                         ssrc: (uint32_t)ssrc
                   clockEpoch: (NSTimeInterval)epoch
{
  if ((self = [super init]) != nil)
    {
      _name = [name copy];
      _port = controlPort;
      _ssrc = ssrc;
      _epoch = epoch;
      _peers = [NSMutableArray array];
      _policy = GMConnectionPolicyAnyone;
    }
  return self;
}

- (NSArray *) peers
{
  return [_peers copy];
}

- (GMPeerConnection *) newPeerWithRole: (GMPeerRole)role
{
  GMPeerConnection *p = [[GMPeerConnection alloc] initWithRole: role
                                                     localSSRC: _ssrc
                                                     localName: _name
                                                    clockEpoch: _epoch];
  p.delegate = self;
  if (_peerConfiguration) _peerConfiguration(p);
  [_peers addObject: p];
  return p;
}

- (GMPeerConnection *) peerOwning: (GMSessionMessage *)m
{
  for (GMPeerConnection *p in _peers)
    if (p.state != GMPeerStateClosed && [p ownsSessionMessage: m]) return p;
  return nil;
}

- (BOOL) mayAccept: (NSData *)address name: (NSString *)name
{
  switch (_policy)
    {
      case GMConnectionPolicyAnyone: return YES;
      case GMConnectionPolicyNobody: return NO;
      case GMConnectionPolicyDirectory:
        return [_delegate session: self directoryAllowsAddress: address
                             name: name];
    }
  return NO;
}

- (void) receiveDatagram: (NSData *)data
                    from: (NSData *)address
               onControl: (BOOL)control
                      at: (NSTimeInterval)now
{
  if ([GMSessionMessage isSessionPacket: data])
    {
      NSError *err = nil;
      GMSessionMessage *m = [GMSessionMessage messageWithData: data error: &err];
      GMPeerConnection *p;

      if (m == nil)
        {
          NSLog(@"gwmidid: %@: bad session packet from %@: %@", _name,
            GMAddressDescription(address), [err localizedDescription]);
          return;
        }
      p = [self peerOwning: m];
      if (p == nil && m.command == GMSessionCommandInvitation && control)
        {
          if (![self mayAccept: address name: m.name])
            {
              NSLog(@"gwmidid: %@: refused invitation from %@ (%@): policy %@",
                _name, m.name, GMAddressDescription(address),
                GMConnectionPolicyString(_policy));
              [_transport sendData: [[GMSessionMessage
                  messageWithCommand: GMSessionCommandReject token: m.token
                                ssrc: _ssrc name: _name] encodedData]
                                to: address control: YES];
              return;
            }
          p = [self newPeerWithRole: GMPeerRoleResponder];
          p.controlAddress = address;
          NSLog(@"gwmidid: %@: invitation from %@ at %@", _name, m.name,
            GMAddressDescription(address));
        }
      if (p == nil) return;
      if (m.command == GMSessionCommandInvitation && !control)
        p.dataAddress = address;
      [p handleSessionMessage: m onControlPort: control at: now];
      return;
    }

  if (!control)
    {
      GMRTPHeader h;
      if (![GMRTPMIDIDecoder parseHeader: data header: &h payloadOffset: NULL
                                   error: NULL])
        return;
      for (GMPeerConnection *p in _peers)
        {
          if (p.state != GMPeerStateClosed && p.remoteSSRC == h.ssrc)
            {
              [p handleRTPPacket: data at: now];
              return;
            }
        }
    }
}

- (GMPeerConnection *) inviteAddress: (NSData *)address at: (NSTimeInterval)now
{
  GMPeerConnection *p = [self newPeerWithRole: GMPeerRoleInitiator];
  p.controlAddress = address;
  p.dataAddress = GMAddressWithPort(address, GMAddressPort(address) + 1);
  [p inviteAt: now];
  [_delegate sessionParticipantsDidChange: self];
  return p;
}

- (void) sendMIDIMessages: (NSArray *)messages at: (NSTimeInterval)now
{
  for (GMPeerConnection *p in [_peers copy])
    [p sendMIDIMessages: messages at: now];
}

- (void) closePeer: (GMPeerConnection *)peer at: (NSTimeInterval)now
{
  [peer closeAt: now];
}

- (void) closeAllAt: (NSTimeInterval)now
{
  for (GMPeerConnection *p in [_peers copy])
    [p closeAt: now];
}

- (NSTimeInterval) nextDeadline
{
  NSTimeInterval best = 0;
  for (GMPeerConnection *p in _peers)
    {
      NSTimeInterval d = [p nextDeadline];
      if (d != 0 && (best == 0 || d < best)) best = d;
    }
  return best;
}

- (void) fireTimersAt: (NSTimeInterval)now
{
  for (GMPeerConnection *p in [_peers copy])
    [p fireTimersAt: now];
}

#pragma mark - GMPeerConnectionDelegate

- (void) peer: (GMPeerConnection *)peer
     sendData: (NSData *)data
onControlPort: (BOOL)control
{
  NSData *to = control ? peer.controlAddress : peer.dataAddress;
  /* A responder learns the data address only from the peer's data IN; a
   * BY before that has nowhere to go on the data port. */
  if (to == nil) return;
  [_transport sendData: data to: to control: control];
}

- (void) peerDidChangeState: (GMPeerConnection *)peer
{
  if (peer.state == GMPeerStateClosed)
    {
      static NSString *reasons[] = { @"", @"closed locally", @"ended by peer",
        @"rejected by peer", @"no answer" };
      NSLog(@"gwmidid: %@: %@ (%@) left: %@", _name, peer.remoteName,
        GMAddressDescription(peer.controlAddress), reasons[peer.closeReason]);
      [_peers removeObject: peer];
    }
  else if (peer.state == GMPeerStateConnected)
    {
      NSLog(@"gwmidid: %@: connected to %@ (%@), latency %.1f ms", _name,
        peer.remoteName, GMAddressDescription(peer.controlAddress),
        peer.latency * 1000.0);
    }
  [_delegate sessionParticipantsDidChange: self];
}

- (void) peer: (GMPeerConnection *)peer didReceiveMIDIMessages: (NSArray *)messages
{
  [_delegate session: self didReceiveMIDIMessages: messages fromPeer: peer];
}

@end
