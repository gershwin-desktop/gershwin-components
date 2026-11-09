/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDLocalSession.h"
#import "NMDSessionMessage.h"
#import "NMDRTPMIDI.h"
#import "NMDSocketAddress.h"

NMDConnectionPolicy NMDConnectionPolicyFromString(NSString *s, BOOL *valid)
{
  if (valid) *valid = YES;
  if ([s isEqualToString: @"anyone"]) return NMDConnectionPolicyAnyone;
  if ([s isEqualToString: @"directory"]) return NMDConnectionPolicyDirectory;
  if ([s isEqualToString: @"nobody"]) return NMDConnectionPolicyNobody;
  if (valid) *valid = NO;
  return NMDConnectionPolicyNobody;
}

NSString *NMDConnectionPolicyString(NMDConnectionPolicy p)
{
  switch (p)
    {
      case NMDConnectionPolicyAnyone: return @"anyone";
      case NMDConnectionPolicyDirectory: return @"directory";
      case NMDConnectionPolicyNobody: return @"nobody";
    }
  return @"nobody";
}

@implementation NMDLocalSession
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
      _policy = NMDConnectionPolicyAnyone;
    }
  return self;
}

- (NSArray *) peers
{
  return [_peers copy];
}

- (NMDPeerConnection *) newPeerWithRole: (NMDPeerRole)role
{
  NMDPeerConnection *p = [[NMDPeerConnection alloc] initWithRole: role
                                                     localSSRC: _ssrc
                                                     localName: _name
                                                    clockEpoch: _epoch];
  p.delegate = self;
  if (_peerConfiguration) _peerConfiguration(p);
  [_peers addObject: p];
  return p;
}

- (NMDPeerConnection *) peerOwning: (NMDSessionMessage *)m
{
  for (NMDPeerConnection *p in _peers)
    if (p.state != NMDPeerStateClosed && [p ownsSessionMessage: m]) return p;
  return nil;
}

- (BOOL) mayAccept: (NSData *)address name: (NSString *)name
{
  switch (_policy)
    {
      case NMDConnectionPolicyAnyone: return YES;
      case NMDConnectionPolicyNobody: return NO;
      case NMDConnectionPolicyDirectory:
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
  if ([NMDSessionMessage isSessionPacket: data])
    {
      NSError *err = nil;
      NMDSessionMessage *m = [NMDSessionMessage messageWithData: data error: &err];
      NMDPeerConnection *p;

      if (m == nil)
        {
          NSLog(@"networkmidid: %@: bad session packet from %@: %@", _name,
            NMDAddressDescription(address), [err localizedDescription]);
          return;
        }
      p = [self peerOwning: m];
      if (p == nil && m.command == NMDSessionCommandInvitation && control)
        {
          if (![self mayAccept: address name: m.name])
            {
              NSLog(@"networkmidid: %@: refused invitation from %@ (%@): policy %@",
                _name, m.name, NMDAddressDescription(address),
                NMDConnectionPolicyString(_policy));
              [_transport sendData: [[NMDSessionMessage
                  messageWithCommand: NMDSessionCommandReject token: m.token
                                ssrc: _ssrc name: _name] encodedData]
                                to: address control: YES];
              return;
            }
          p = [self newPeerWithRole: NMDPeerRoleResponder];
          p.controlAddress = address;
          NSLog(@"networkmidid: %@: invitation from %@ at %@", _name, m.name,
            NMDAddressDescription(address));
        }
      if (p == nil) return;
      if (m.command == NMDSessionCommandInvitation && !control)
        p.dataAddress = address;
      [p handleSessionMessage: m onControlPort: control at: now];
      return;
    }

  if (!control)
    {
      NMDRTPHeader h;
      if (![NMDRTPMIDIDecoder parseHeader: data header: &h payloadOffset: NULL
                                   error: NULL])
        return;
      for (NMDPeerConnection *p in _peers)
        {
          if (p.state != NMDPeerStateClosed && p.remoteSSRC == h.ssrc)
            {
              [p handleRTPPacket: data at: now];
              return;
            }
        }
    }
}

- (NMDPeerConnection *) inviteAddress: (NSData *)address at: (NSTimeInterval)now
{
  NMDPeerConnection *p = [self newPeerWithRole: NMDPeerRoleInitiator];
  p.controlAddress = address;
  p.dataAddress = NMDAddressWithPort(address, NMDAddressPort(address) + 1);
  [p inviteAt: now];
  [_delegate sessionParticipantsDidChange: self];
  return p;
}

- (void) sendMIDIMessages: (NSArray *)messages at: (NSTimeInterval)now
{
  for (NMDPeerConnection *p in [_peers copy])
    [p sendMIDIMessages: messages at: now];
}

- (void) closePeer: (NMDPeerConnection *)peer at: (NSTimeInterval)now
{
  [peer closeAt: now];
}

- (void) closeAllAt: (NSTimeInterval)now
{
  for (NMDPeerConnection *p in [_peers copy])
    [p closeAt: now];
}

- (NSTimeInterval) nextDeadline
{
  NSTimeInterval best = 0;
  for (NMDPeerConnection *p in _peers)
    {
      NSTimeInterval d = [p nextDeadline];
      if (d != 0 && (best == 0 || d < best)) best = d;
    }
  return best;
}

- (void) fireTimersAt: (NSTimeInterval)now
{
  for (NMDPeerConnection *p in [_peers copy])
    [p fireTimersAt: now];
}

#pragma mark - NMDPeerConnectionDelegate

- (void) peer: (NMDPeerConnection *)peer
     sendData: (NSData *)data
onControlPort: (BOOL)control
{
  NSData *to = control ? peer.controlAddress : peer.dataAddress;
  /* A responder learns the data address only from the peer's data IN; a
   * BY before that has nowhere to go on the data port. */
  if (to == nil) return;
  [_transport sendData: data to: to control: control];
}

- (void) peerDidChangeState: (NMDPeerConnection *)peer
{
  if (peer.state == NMDPeerStateClosed)
    {
      static NSString *reasons[] = { @"", @"closed locally", @"ended by peer",
        @"rejected by peer", @"no answer" };
      NSLog(@"networkmidid: %@: %@ (%@) left: %@", _name, peer.remoteName,
        NMDAddressDescription(peer.controlAddress), reasons[peer.closeReason]);
      [_delegate session: self peerDidClose: peer];
      [_peers removeObject: peer];
    }
  else if (peer.state == NMDPeerStateConnected)
    {
      NSLog(@"networkmidid: %@: connected to %@ (%@), latency %.1f ms", _name,
        peer.remoteName, NMDAddressDescription(peer.controlAddress),
        peer.latency * 1000.0);
    }
  [_delegate sessionParticipantsDidChange: self];
}

- (void) peerDidUpdateLatency: (NMDPeerConnection *)peer
{
  [_delegate sessionParticipantLatencyDidChange: self];
}

- (void) peer: (NMDPeerConnection *)peer didReceiveMIDIMessages: (NSArray *)messages
{
  [_delegate session: self didReceiveMIDIMessages: messages fromPeer: peer];
}

@end
