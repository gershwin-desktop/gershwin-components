/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#define _GNU_SOURCE
#include <pthread.h>
#include <stdlib.h>
#include <time.h>
#include "gad.h"

static unsigned (*gIdleAdd)(int (*)(void *), void *);

void gad_main_call_init(unsigned (*idle_add)(int (*)(void *), void *))
{
  gIdleAdd = idle_add;
}

typedef struct
{
  void *(*fn)(void *);
  void *arg;
  void (*destroy)(void *);
  void *result;
  int done;
  int abandoned;
  pthread_mutex_t lock;
  pthread_cond_t cond;
} MainCall;

static int main_call_idle(void *data)
{
  MainCall *c = data;
  void *result = c->fn(c->arg);
  pthread_mutex_lock(&c->lock);
  if (c->abandoned)
    {
      pthread_mutex_unlock(&c->lock);
      if (c->destroy)
        c->destroy(result);
      free(c);
      return 0;
    }
  c->result = result;
  c->done = 1;
  pthread_cond_signal(&c->cond);
  pthread_mutex_unlock(&c->lock);
  return 0;
}

void *gad_main_call(void *(*fn)(void *), void *arg, void (*destroy)(void *),
                    int timeout_ms)
{
  MainCall *c = calloc(1, sizeof *c);
  if (c == NULL || gIdleAdd == NULL)
    {
      free(c);
      return NULL;
    }
  c->fn = fn;
  c->arg = arg;
  c->destroy = destroy;
  pthread_mutex_init(&c->lock, NULL);
  pthread_cond_init(&c->cond, NULL);

  struct timespec deadline;
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_nsec += timeout_ms * 1000000L;
  deadline.tv_sec += deadline.tv_nsec / 1000000000L;
  deadline.tv_nsec %= 1000000000L;

  gIdleAdd(main_call_idle, c);
  pthread_mutex_lock(&c->lock);
  while (!c->done && pthread_cond_timedwait(&c->cond, &c->lock, &deadline) == 0)
    ;
  void *result = NULL;
  if (c->done)
    {
      result = c->result;
      pthread_mutex_unlock(&c->lock);
      pthread_mutex_destroy(&c->lock);
      pthread_cond_destroy(&c->cond);
      free(c);
    }
  else
    {
      /* The main loop is busy (modal dialog, long handler); main_call_idle frees. */
      c->abandoned = 1;
      pthread_mutex_unlock(&c->lock);
    }
  return result;
}
