/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#ifndef GM_BYTE_ORDER_H
#define GM_BYTE_ORDER_H

#include <stdint.h>

/* Byte-wise so the wire format is independent of host endianness and of
 * alignment inside a datagram. */
static inline uint16_t GMReadBE16(const uint8_t *p)
{
  return (uint16_t)((p[0] << 8) | p[1]);
}

static inline uint32_t GMReadBE32(const uint8_t *p)
{
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
    | ((uint32_t)p[2] << 8) | p[3];
}

static inline uint64_t GMReadBE64(const uint8_t *p)
{
  return ((uint64_t)GMReadBE32(p) << 32) | GMReadBE32(p + 4);
}

static inline void GMWriteBE16(uint8_t *p, uint16_t v)
{
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)v;
}

static inline void GMWriteBE32(uint8_t *p, uint32_t v)
{
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

static inline void GMWriteBE64(uint8_t *p, uint64_t v)
{
  GMWriteBE32(p, (uint32_t)(v >> 32));
  GMWriteBE32(p + 4, (uint32_t)v);
}

#endif
