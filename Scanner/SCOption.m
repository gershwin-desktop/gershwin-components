/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCOption.h"
#include <math.h>
#include <string.h>

static NSString *
SCString(SANE_String_Const s)
{
  return s ? [NSString stringWithUTF8String: s] : @"";
}

@implementation SCOption

- (instancetype) initWithDescriptor: (const SANE_Option_Descriptor *)d
                              index: (SANE_Int)index
                         groupTitle: (NSString *)group
{
  self = [super init];
  if (self)
    {
      _index = index;
      _name = SCString(d->name);
      _title = SCString(d->title);
      _help = SCString(d->desc);
      _groupTitle = group;
      _unit = d->unit;
      _bufferSize = d->size;
      _active = SANE_OPTION_IS_ACTIVE(d->cap);
      _settable = SANE_OPTION_IS_SETTABLE(d->cap);
      _advanced = (d->cap & SANE_CAP_ADVANCED) != 0;
      _canBeAutomatic = (d->cap & SANE_CAP_AUTOMATIC) != 0;

      switch (d->type)
        {
          case SANE_TYPE_BOOL:   _type = SCOptionTypeBool;   break;
          case SANE_TYPE_INT:    _type = SCOptionTypeInt;    break;
          case SANE_TYPE_FIXED:  _type = SCOptionTypeFixed;  break;
          case SANE_TYPE_STRING: _type = SCOptionTypeString; break;
          case SANE_TYPE_BUTTON: _type = SCOptionTypeButton; break;
          default:               _type = SCOptionTypeGroup;  break;
        }

      if (_type == SCOptionTypeInt || _type == SCOptionTypeFixed
          || _type == SCOptionTypeBool)
        {
          _count = MAX(1, d->size / (SANE_Int)sizeof(SANE_Word));
        }
      else
        {
          _count = 1;
        }

      if (d->constraint_type == SANE_CONSTRAINT_RANGE)
        {
          const SANE_Range *r = d->constraint.range;
          BOOL fixed = (_type == SCOptionTypeFixed);

          _constraint = SCOptionConstraintRange;
          _minimum = fixed ? SANE_UNFIX(r->min) : r->min;
          _maximum = fixed ? SANE_UNFIX(r->max) : r->max;
          _step = fixed ? SANE_UNFIX(r->quant) : r->quant;
        }
      else if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST)
        {
          const SANE_Word *w = d->constraint.word_list;
          NSMutableArray *list = [NSMutableArray array];
          SANE_Int i;

          for (i = 1; i <= w[0]; i++)
            {
              [list addObject: (_type == SCOptionTypeFixed)
                ? [NSNumber numberWithDouble: SANE_UNFIX(w[i])]
                : [NSNumber numberWithInt: w[i]]];
            }
          _constraint = SCOptionConstraintList;
          _listValues = list;
        }
      else if (d->constraint_type == SANE_CONSTRAINT_STRING_LIST)
        {
          const SANE_String_Const *s = d->constraint.string_list;
          NSMutableArray *list = [NSMutableArray array];

          while (*s != NULL)
            {
              [list addObject: SCString(*s)];
              s++;
            }
          _constraint = SCOptionConstraintList;
          _listValues = list;
        }
    }
  return self;
}

- (NSString *) description
{
  return [NSString stringWithFormat: @"<SCOption %d %@ = %@>",
                   (int)_index, _name, _value];
}

- (NSNumber *) numberFromWord: (SANE_Word)w
{
  switch (_type)
    {
      case SCOptionTypeBool:
        return [NSNumber numberWithBool: w == SANE_TRUE];
      case SCOptionTypeFixed:
        return [NSNumber numberWithDouble: SANE_UNFIX(w)];
      default:
        return [NSNumber numberWithInt: w];
    }
}

- (SANE_Word) wordFromNumber: (NSNumber *)n
{
  switch (_type)
    {
      case SCOptionTypeBool:
        return [n boolValue] ? SANE_TRUE : SANE_FALSE;
      case SCOptionTypeFixed:
        return SANE_FIX([n doubleValue]);
      default:
        return (SANE_Word)lround([n doubleValue]);
    }
}

- (id) valueFromBuffer: (const void *)buffer
{
  const SANE_Word *words = buffer;
  NSMutableArray *array;
  NSUInteger i;

  switch (_type)
    {
      case SCOptionTypeString:
        return SCString(buffer);
      case SCOptionTypeButton:
      case SCOptionTypeGroup:
        return nil;
      default:
        if (_count == 1)
          {
            return [self numberFromWord: words[0]];
          }
        array = [NSMutableArray arrayWithCapacity: _count];
        for (i = 0; i < _count; i++)
          {
            [array addObject: [self numberFromWord: words[i]]];
          }
        return array;
    }
}

- (BOOL) fillBuffer: (void *)buffer fromValue: (id)value
{
  SANE_Word *words = buffer;
  NSUInteger i;

  switch (_type)
    {
      case SCOptionTypeString:
        {
          const char *utf8;

          if (![value isKindOfClass: [NSString class]])
            {
              return NO;
            }
          utf8 = [value UTF8String];
          if (strlen(utf8) + 1 > _bufferSize)
            {
              return NO;
            }
          memset(buffer, 0, _bufferSize);
          strcpy(buffer, utf8);
          return YES;
        }
      case SCOptionTypeButton:
      case SCOptionTypeGroup:
        return NO;
      default:
        if (_count == 1)
          {
            if (![value isKindOfClass: [NSNumber class]])
              {
                return NO;
              }
            words[0] = [self wordFromNumber: value];
            return YES;
          }
        if (![value isKindOfClass: [NSArray class]] || [value count] != _count)
          {
            return NO;
          }
        for (i = 0; i < _count; i++)
          {
            words[i] = [self wordFromNumber: [value objectAtIndex: i]];
          }
        return YES;
    }
}

- (NSString *) unitString
{
  switch (_unit)
    {
      case SANE_UNIT_PIXEL:       return @"px";
      case SANE_UNIT_BIT:         return @"bit";
      case SANE_UNIT_MM:          return @"mm";
      case SANE_UNIT_DPI:         return @"dpi";
      case SANE_UNIT_PERCENT:     return @"%";
      case SANE_UNIT_MICROSECOND: return @"us";
      default:                    return nil;
    }
}

- (double) constrainedNumber: (double)number
{
  if (_constraint == SCOptionConstraintRange)
    {
      double v = MIN(_maximum, MAX(_minimum, number));

      if (_step > 0)
        {
          v = _minimum + round((v - _minimum) / _step) * _step;
          v = MIN(_maximum, v);
        }
      if (_type == SCOptionTypeInt)
        {
          v = round(v);
        }
      return v;
    }
  if (_constraint == SCOptionConstraintList && [_listValues count] > 0
      && [[_listValues objectAtIndex: 0] isKindOfClass: [NSNumber class]])
    {
      double best = [[_listValues objectAtIndex: 0] doubleValue];

      for (NSNumber *n in _listValues)
        {
          if (fabs([n doubleValue] - number) < fabs(best - number))
            {
              best = [n doubleValue];
            }
        }
      return best;
    }
  return (_type == SCOptionTypeInt) ? round(number) : number;
}

@end
