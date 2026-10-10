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

double ParamMapping::toNormalized(float plain) const {
  const double p = std::min<double>(max, std::max<double>(min, plain));
  if (max <= min) return 0;
  if (logarithmic) {
    return std::log(p / min) / std::log(static_cast<double>(max) / min);
  }
  return (p - min) / (static_cast<double>(max) - min);
}

AudParameter::AudParameter(const EngineParam& param)
    : mapping_(ParamMapping::of(param)) {
  Steinberg::UString(info.title, USTRINGSIZE(info.title))
      .fromAscii((param.nodeId + " " + param.name).c_str());
  Steinberg::UString(info.shortTitle, USTRINGSIZE(info.shortTitle))
      .fromAscii(param.name.c_str());
  Steinberg::UString(info.units, USTRINGSIZE(info.units))
      .fromAscii(param.unit.c_str());
  std::snprintf(unit_, sizeof(unit_), "%s", param.unit.c_str());
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
  char text[64];
  const float plain = mapping_.toPlain(normalized);
  if (mapping_.steps >= 2) {
    std::snprintf(text, sizeof(text), "%d", static_cast<int>(plain));
  } else if (unit_[0] != 0) {
    std::snprintf(text, sizeof(text), "%.2f %s", plain, unit_);
  } else {
    std::snprintf(text, sizeof(text), "%.3f", plain);
  }
  Steinberg::UString(string, 128).fromAscii(text);
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
