/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDALSASequencer.h"
#import "NMDDescriptorWatcher.h"
#import "NMDMIDIStreamParser.h"
#import "NMDRTPMIDI.h"

NSString * const NMDLocalPortIdentifier = @"identifier";
NSString * const NMDLocalPortName = @"name";
NSString * const NMDLocalPortCanSend = @"canSend";
NSString * const NMDLocalPortCanReceive = @"canReceive";

#if NMD_HAVE_ALSA

#include <alsa/asoundlib.h>
#include <poll.h>

/* ALSA's own MIDI drivers hand sysex over in pieces of this size, and
 * applications expect to reassemble them. */
#define NMD_SYSEX_EVENT_CHUNK 256

static NSError *NMDALSAError(NSString *what, int err)
{
  return [NSError errorWithDomain: @"NMDALSASequencerErrorDomain" code: -err
    userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat:
      @"ALSA sequencer: %@: %s", what, snd_strerror(err)]}];
}

@implementation NMDALSASequencer
{
  snd_seq_t *_seq;
  snd_midi_event_t *_decoder;
  snd_midi_event_t *_encoder;
  NSMutableArray *_watchers;
  NSMutableDictionary *_parsers;   /* port -> NMDMIDIStreamParser */
  uint8_t *_decodeBuffer;
  int _announcePort;               /* receives the system's port events */
}

@synthesize delegate = _delegate;

- (instancetype) initWithClientName: (NSString *)name error: (NSError **)error
{
  int err, n, i;
  struct pollfd *pfd;

  if ((self = [super init]) == nil) return nil;
  _watchers = [NSMutableArray array];
  _parsers = [NSMutableDictionary dictionary];
  if ((err = snd_seq_open(&_seq, "default", SND_SEQ_OPEN_DUPLEX,
      SND_SEQ_NONBLOCK)) < 0)
    {
      _seq = NULL;
      if (error) *error = NMDALSAError(@"cannot open the sequencer", err);
      return nil;
    }
  snd_seq_set_client_name(_seq, [name UTF8String]);
  if ((err = snd_midi_event_new(NMD_RTP_MIDI_MAX_SYSEX, &_decoder)) < 0
    || (err = snd_midi_event_new(NMD_RTP_MIDI_MAX_SYSEX, &_encoder)) < 0)
    {
      if (error) *error = NMDALSAError(@"cannot create the event coder", err);
      [self close];
      return nil;
    }
  /* Every decoded event becomes a complete message with its status byte;
   * the stream parser then has nothing to undo. */
  snd_midi_event_no_status(_decoder, 1);
  _decodeBuffer = malloc(NMD_RTP_MIDI_MAX_SYSEX);

  /* Ports of other programs come and go (a USB keyboard plugged in, a
   * synth started); the system announces that on a port of its own, which
   * needs a port of ours to arrive at.  No subscription capabilities, so
   * applications do not list it. */
  _announcePort = snd_seq_create_simple_port(_seq, "system announcements",
    SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_NO_EXPORT,
    SND_SEQ_PORT_TYPE_APPLICATION);
  if (_announcePort < 0
    || (err = snd_seq_connect_from(_seq, _announcePort, SND_SEQ_CLIENT_SYSTEM,
      SND_SEQ_PORT_SYSTEM_ANNOUNCE)) < 0)
    {
      if (error) *error = NMDALSAError(@"cannot follow port changes",
        _announcePort < 0 ? _announcePort : err);
      [self close];
      return nil;
    }

  n = snd_seq_poll_descriptors_count(_seq, POLLIN);
  pfd = calloc((size_t)n, sizeof *pfd);
  n = snd_seq_poll_descriptors(_seq, pfd, (unsigned)n, POLLIN);
  for (i = 0; i < n; i++)
    {
      __weak NMDALSASequencer *weakSelf = self;
      [_watchers addObject: [[NMDDescriptorWatcher alloc]
        initWithDescriptor: pfd[i].fd handler: ^{ [weakSelf drain]; }]];
    }
  free(pfd);
  return self;
}

- (NSString *) portLayerDescription
{
  return [NSString stringWithFormat: @"ALSA sequencer client %d",
    _seq ? snd_seq_client_id(_seq) : -1];
}

- (NSString *) addressOfPort: (int)port
{
  return [NSString stringWithFormat: @"%d:%d", snd_seq_client_id(_seq), port];
}

- (int) createPortNamed: (NSString *)name error: (NSError **)error
{
  int port = snd_seq_create_simple_port(_seq, [name UTF8String],
    SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ
    | SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE
    | SND_SEQ_PORT_CAP_DUPLEX,
    SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_SOFTWARE
    | SND_SEQ_PORT_TYPE_PORT | SND_SEQ_PORT_TYPE_APPLICATION);
  if (port < 0)
    {
      if (error) *error = NMDALSAError([NSString stringWithFormat:
        @"cannot create port \"%@\"", name], port);
      return -1;
    }
  [_parsers setObject: [NMDMIDIStreamParser new] forKey: @(port)];
  return port;
}

- (void) removePort: (int)port
{
  [_parsers removeObjectForKey: @(port)];
  if (_seq) snd_seq_delete_simple_port(_seq, port);
}

- (void) renamePort: (int)port to: (NSString *)name
{
  snd_seq_port_info_t *info;
  snd_seq_port_info_alloca(&info);
  if (snd_seq_get_port_info(_seq, port, info) < 0) return;
  snd_seq_port_info_set_name(info, [name UTF8String]);
  snd_seq_set_port_info(_seq, port, info);
}

- (void) drain
{
  NSMutableDictionary *byPort = [NSMutableDictionary dictionary];
  snd_seq_event_t *ev;
  int r;
  BOOL portsChanged = NO;

  while ((r = snd_seq_event_input(_seq, &ev)) >= 0 || r == -ENOSPC)
    {
      NMDMIDIStreamParser *parser;
      long n;
      NSArray *msgs;

      if (r == -ENOSPC)
        {
          /* The kernel dropped events because we were too slow; there is
           * nothing to recover them from. */
          NSLog(@"networkmidid: ALSA input overrun, events lost");
          continue;
        }
      if (ev == NULL) continue;
      if (ev->dest.port == _announcePort)
        {
          switch (ev->type)
            {
              case SND_SEQ_EVENT_CLIENT_START: case SND_SEQ_EVENT_CLIENT_EXIT:
              case SND_SEQ_EVENT_CLIENT_CHANGE: case SND_SEQ_EVENT_PORT_START:
              case SND_SEQ_EVENT_PORT_EXIT: case SND_SEQ_EVENT_PORT_CHANGE:
                portsChanged = YES;
                break;
              default:
                break;
            }
          continue;
        }
      parser = [_parsers objectForKey: @(ev->dest.port)];
      if (parser == nil) continue;
      snd_midi_event_reset_decode(_decoder);
      n = snd_midi_event_decode(_decoder, _decodeBuffer,
        NMD_RTP_MIDI_MAX_SYSEX, ev);
      if (n <= 0) continue; /* not a MIDI event (port subscribed etc.) */
      msgs = [parser messagesFromBytes: _decodeBuffer length: (NSUInteger)n];
      if ([msgs count] > 0)
        {
          NSMutableArray *a = [byPort objectForKey: @(ev->dest.port)];
          if (a == nil)
            [byPort setObject: (a = [NSMutableArray array])
                       forKey: @(ev->dest.port)];
          [a addObjectsFromArray: msgs];
        }
    }
  /* One delegate call per port and wakeup, so the messages of one burst go
   * out in as few packets as possible. */
  for (NSNumber *port in byPort)
    [_delegate ports: self didReceiveMessages: [byPort objectForKey: port]
              onPort: [port intValue]];
  if (portsChanged)
    [_delegate portsDidChangeLocalPorts: self];
}

- (NSArray *) localPorts
{
  NSMutableArray *out = [NSMutableArray array];
  snd_seq_client_info_t *ci;
  snd_seq_port_info_t *pi;
  int me = snd_seq_client_id(_seq);

  snd_seq_client_info_alloca(&ci);
  snd_seq_port_info_alloca(&pi);
  snd_seq_client_info_set_client(ci, -1);
  while (snd_seq_query_next_client(_seq, ci) >= 0)
    {
      int client = snd_seq_client_info_get_client(ci);
      NSString *clientName;
      if (client == me || client == SND_SEQ_CLIENT_SYSTEM) continue;
      clientName = [NSString stringWithUTF8String:
        snd_seq_client_info_get_name(ci)];
      snd_seq_port_info_set_client(pi, client);
      snd_seq_port_info_set_port(pi, -1);
      while (snd_seq_query_next_port(_seq, pi) >= 0)
        {
          unsigned caps = snd_seq_port_info_get_capability(pi);
          BOOL canSend = (caps & SND_SEQ_PORT_CAP_READ)
            && (caps & SND_SEQ_PORT_CAP_SUBS_READ);
          BOOL canReceive = (caps & SND_SEQ_PORT_CAP_WRITE)
            && (caps & SND_SEQ_PORT_CAP_SUBS_WRITE);
          NSString *portName = [NSString stringWithUTF8String:
            snd_seq_port_info_get_name(pi)];
          NSString *name;
          if ((caps & SND_SEQ_PORT_CAP_NO_EXPORT) || (!canSend && !canReceive))
            continue;
          /* Hardware ports usually repeat the device name already. */
          name = [portName hasPrefix: clientName] ? portName
            : [NSString stringWithFormat: @"%@: %@", clientName, portName];
          [out addObject: @{
            NMDLocalPortIdentifier: [NSString stringWithFormat: @"%d:%d",
              client, snd_seq_port_info_get_port(pi)],
            NMDLocalPortName: name,
            NMDLocalPortCanSend: @(canSend),
            NMDLocalPortCanReceive: @(canReceive) }];
        }
    }
  return out;
}

static BOOL NMDParseAddress(NSString *identifier, int *client, int *port)
{
  return sscanf([identifier UTF8String], "%d:%d", client, port) == 2;
}

- (BOOL) connectPort: (int)port
         toLocalPort: (NSString *)identifier
               input: (BOOL)input
               error: (NSError **)error
{
  int client, other, err;
  if (!NMDParseAddress(identifier, &client, &other))
    {
      if (error) *error = NMDALSAError(@"bad port address", -EINVAL);
      return NO;
    }
  err = input ? snd_seq_connect_from(_seq, port, client, other)
              : snd_seq_connect_to(_seq, port, client, other);
  /* Already connected (by the user, with another tool) is what we want. */
  if (err < 0 && err != -EBUSY)
    {
      if (error) *error = NMDALSAError([NSString stringWithFormat:
        @"cannot connect %@", identifier], err);
      return NO;
    }
  return YES;
}

- (void) disconnectPort: (int)port
          fromLocalPort: (NSString *)identifier
                  input: (BOOL)input
{
  int client, other;
  if (!NMDParseAddress(identifier, &client, &other)) return;
  if (input)
    snd_seq_disconnect_from(_seq, port, client, other);
  else
    snd_seq_disconnect_to(_seq, port, client, other);
}

- (void) output: (snd_seq_event_t *)ev port: (int)port
{
  int err;
  snd_seq_ev_set_source(ev, port);
  snd_seq_ev_set_subs(ev);
  snd_seq_ev_set_direct(ev);
  if ((err = snd_seq_event_output_direct(_seq, ev)) < 0)
    NSLog(@"networkmidid: ALSA output on port %d failed: %s", port, snd_strerror(err));
}

- (void) sendMessages: (NSArray *)messages fromPort: (int)port
{
  for (NSData *m in messages)
    {
      const uint8_t *b = [m bytes];
      NSUInteger len = [m length];
      snd_seq_event_t ev;

      if (len == 0) continue;
      if (b[0] == 0xF0)
        {
          NSUInteger off;
          for (off = 0; off < len; off += NMD_SYSEX_EVENT_CHUNK)
            {
              NSUInteger n = MIN(len - off, (NSUInteger)NMD_SYSEX_EVENT_CHUNK);
              snd_seq_ev_clear(&ev);
              snd_seq_ev_set_sysex(&ev, (unsigned)n, (void *)(b + off));
              [self output: &ev port: port];
            }
          continue;
        }
      snd_seq_ev_clear(&ev);
      snd_midi_event_reset_encode(_encoder);
      if (snd_midi_event_encode(_encoder, b, (long)len, &ev) == (long)len
        && ev.type != SND_SEQ_EVENT_NONE)
        {
          [self output: &ev port: port];
        }
    }
}

- (void) close
{
  for (NMDDescriptorWatcher *w in _watchers) [w invalidate];
  [_watchers removeAllObjects];
  if (_decoder) snd_midi_event_free(_decoder);
  if (_encoder) snd_midi_event_free(_encoder);
  _decoder = _encoder = NULL;
  free(_decodeBuffer);
  _decodeBuffer = NULL;
  if (_seq) snd_seq_close(_seq);
  _seq = NULL;
}

- (void) dealloc
{
  [self close];
}

@end

id<NMDMIDIPorts> NMDMIDIPortsOpen(NSString *clientName, NSError **error)
{
  return [[NMDALSASequencer alloc] initWithClientName: clientName error: error];
}

#else /* !NMD_HAVE_ALSA */

id<NMDMIDIPorts> NMDMIDIPortsOpen(NSString *clientName, NSError **error)
{
  if (error)
    *error = [NSError errorWithDomain: @"NMDALSASequencerErrorDomain" code: 1
      userInfo: @{NSLocalizedDescriptionKey:
        @"this system has no MIDI port layer for networkmidid yet "
        @"(the sndio one is still to be written)"}];
  return nil;
}

#endif
