// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_param.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "pluginterfaces/base/ustring.h"

namespace aud_vst3 {

using Steinberg::Vst::ParamValue;

namespace {

// A character of a text and the bytes it takes.
struct CodePoint {
  char32_t value;
  size_t length;
};

// The character whose UTF-8 starts at `text[at]`; length 0 for none: a
// byte no sequence starts with, a missing continuation byte, an overlong
// encoding, a surrogate or a value above U+10FFFF.
CodePoint utf8At(const std::string& text, size_t at) {
  const auto byte = [&](size_t i) {
    return static_cast<unsigned char>(text[i]);
  };
  const unsigned char lead = byte(at);
  if (lead < 0x80) return {lead, 1};
  // A continuation byte, or 0xF8 to 0xFF, starts no sequence.
  if (lead < 0xC0 || lead >= 0xF8) return {0, 0};
  const size_t length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2;
  if (text.size() - at < length) return {0, 0};
  char32_t value = lead & (0x7F >> length);
  for (size_t i = at + 1; i < at + length; ++i) {
    if ((byte(i) & 0xC0) != 0x80) return {0, 0};
    value = (value << 6) | (byte(i) & 0x3F);
  }
  // The smallest value of each length, below which a sequence is overlong.
  constexpr char32_t kSmallest[] = {0, 0, 0x80, 0x800, 0x10000};
  if (value < kSmallest[length] || value > 0x10FFFF ||
      (value >= 0xD800 && value <= 0xDFFF)) {
    return {0, 0};
  }
  return {value, length};
}

// Whether all of `text` is UTF-8.
bool isUtf8(const std::string& text) {
  for (size_t at = 0; at < text.size();) {
    const size_t length = utf8At(text, at).length;
    if (length == 0) return false;
    at += length;
  }
  return true;
}

}  // namespace

// #############################################################################
void writeUtf16(const std::string& text, Steinberg::Vst::TChar* string,
                size_t size) {
  if (size == 0) return;
  // Decided for the whole text, so that one bad byte does not mix both.
  const bool utf8 = isUtf8(text);
  size_t length = 0;
  for (size_t at = 0; at < text.size();) {
    const CodePoint c =
        utf8 ? utf8At(text, at)
             : CodePoint{static_cast<unsigned char>(text[at]), 1};
    // Beyond U+FFFF a surrogate pair, which only goes whole.
    const size_t units = c.value > 0xFFFF ? 2 : 1;
    if (length + units > size - 1) break;
    if (units == 2) {
      const char32_t offset = c.value - 0x10000;
      string[length++] = static_cast<char16_t>(0xD800 + (offset >> 10));
      string[length++] = static_cast<char16_t>(0xDC00 + (offset & 0x3FF));
    } else {
      string[length++] = static_cast<char16_t>(c.value);
    }
    at += c.length;
  }
  string[length] = 0;
}

// #############################################################################
// ParamMapping

// .............................................................................
ParamMapping ParamMapping::of(const EngineParam& param) {
  ParamMapping mapping;
  mapping.id = param.id;
  mapping.min = param.min;
  mapping.max = param.max;
  mapping.logarithmic =
      (param.flags & AUD_PARAM_LOGARITHMIC) != 0 && param.min > 0;
  if ((param.flags & AUD_PARAM_STEPPED) != 0 && param.steps >= 2) {
    mapping.steps = param.steps;
  }
  return mapping;
}

// .............................................................................
float ParamMapping::toPlain(double normalized) const {
  const double n = std::min(1.0, std::max(0.0, normalized));
  double plain;
  if (steps >= 2) {
    const double step = std::round(n * (steps - 1));
    plain = min + step * (static_cast<double>(max) - min) / (steps - 1);
  } else if (logarithmic) {
    plain = min * std::pow(static_cast<double>(max) / min, n);
  } else {
    plain = min + n * (static_cast<double>(max) - min);
  }
  return static_cast<float>(std::min<double>(max, std::max<double>(min, plain)));
}

// .............................................................................
double ParamMapping::toNormalized(float plain) const {
  const double p = std::min<double>(max, std::max<double>(min, plain));
  if (max <= min) return 0;
  if (logarithmic) {
    return std::log(p / min) / std::log(static_cast<double>(max) / min);
  }
  return (p - min) / (static_cast<double>(max) - min);
}

// #############################################################################
// AudParameter

// .............................................................................
AudParameter::AudParameter(const EngineParam& param, const std::string& title)
    : mapping_(ParamMapping::of(param)) {
  writeUtf16(title.empty() ? param.nodeId + " " + param.name : title,
             info.title, USTRINGSIZE(info.title));
  writeUtf16(title.empty() ? param.name : title, info.shortTitle,
             USTRINGSIZE(info.shortTitle));
  writeUtf16(param.unit, info.units, USTRINGSIZE(info.units));
  unit_ = param.unit;
  info.id = param.id;
  info.stepCount = mapping_.steps >= 2 ? mapping_.steps - 1 : 0;
  info.flags = (param.flags & AUD_PARAM_AUTOMATABLE) != 0
                   ? Steinberg::Vst::ParameterInfo::kCanAutomate
                   : 0;
  if (mapping_.steps >= 2) {
    info.flags |= Steinberg::Vst::ParameterInfo::kIsList;
  }
  info.unitId = Steinberg::Vst::kRootUnitId;
  info.defaultNormalizedValue = mapping_.toNormalized(param.defaultValue);
  setNormalized(info.defaultNormalizedValue);
}

void AudParameter::toString(ParamValue normalized,
                            Steinberg::Vst::String128 string) const {
  char number[64];
  const float plain = mapping_.toPlain(normalized);
  if (mapping_.steps >= 2) {
    std::snprintf(number, sizeof(number), "%d", static_cast<int>(plain));
    writeUtf16(number, string, 128);
  } else if (!unit_.empty()) {
    // The unit whole: a cut in a byte buffer could split one of its
    // characters.
    std::snprintf(number, sizeof(number), "%.2f ", plain);
    writeUtf16(number + unit_, string, 128);
  } else {
    std::snprintf(number, sizeof(number), "%.3f", plain);
    writeUtf16(number, string, 128);
  }
}

bool AudParameter::fromString(const Steinberg::Vst::TChar* string,
                              ParamValue& normalized) const {
  Steinberg::UString wrapper(const_cast<Steinberg::Vst::TChar*>(string), 128);
  double plain = 0;
  if (!wrapper.scanFloat(plain)) return false;
  normalized = mapping_.toNormalized(static_cast<float>(plain));
  return true;
}

ParamValue AudParameter::toPlain(ParamValue normalized) const {
  return mapping_.toPlain(normalized);
}

ParamValue AudParameter::toNormalized(ParamValue plain) const {
  return mapping_.toNormalized(static_cast<float>(plain));
}

}  // namespace aud_vst3
