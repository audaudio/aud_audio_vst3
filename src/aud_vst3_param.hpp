// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The mapping between a graph parameter's plain value and the normalized
// value of VST3, and the VST3 parameter object over it (ticket 24).

#ifndef AUD_VST3_PARAM_HPP
#define AUD_VST3_PARAM_HPP

#include <cstdint>
#include <string>

// Through the single-component header: it renames the controller's
// setState and getState before it includes the controller headers, and
// every file of the plugin must see them renamed.
#include "public.sdk/source/vst/vstsinglecomponenteffect.h"

#include "aud_vst3_engine.hpp"

namespace aud_vst3 {

// #############################################################################
// [any thread] Maps between plain and normalized values: linear,
// logarithmic (AUD_PARAM_LOGARITHMIC with a positive minimum) or stepped
// (AUD_PARAM_STEPPED with at least two steps). Holds no pointers, so the
// realtime thread reads it from a sorted array.
struct ParamMapping {
  // ...........................................................................
  // The stable id of the parameter.
  uint32_t id = 0;

  // ...........................................................................
  // The range of the plain value.
  float min = 0;
  float max = 1;

  // ...........................................................................
  // Whether the mapping is logarithmic, and the steps of a stepped one; 0
  // for a continuous one.
  bool logarithmic = false;
  uint32_t steps = 0;

  // ...........................................................................
  // The mapping of `param`.
  static ParamMapping of(const EngineParam& param);

  // ...........................................................................
  // The plain value of `normalized`, which is clamped to 0 to 1 first.
  float toPlain(double normalized) const;

  // ...........................................................................
  // The normalized value of `plain`, which is clamped to the range first.
  double toNormalized(float plain) const;
};

// #############################################################################
// The VST3 parameter of one graph parameter.
class AudParameter : public Steinberg::Vst::Parameter {
 public:
  // ...........................................................................
  // Creates the parameter of `param`: its stable id, titles, unit and
  // steps, with the value of the bundled document as the default. `title`
  // replaces the title "<node id> <name>" when it is not empty.
  explicit AudParameter(const EngineParam& param,
                        const std::string& title = std::string());

  // ...........................................................................
  // The mapping of the parameter, for the realtime thread.
  const ParamMapping& mapping() const { return mapping_; }

  void toString(Steinberg::Vst::ParamValue normalized,
                Steinberg::Vst::String128 string) const SMTG_OVERRIDE;
  bool fromString(const Steinberg::Vst::TChar* string,
                  Steinberg::Vst::ParamValue& normalized) const SMTG_OVERRIDE;
  Steinberg::Vst::ParamValue toPlain(
      Steinberg::Vst::ParamValue normalized) const SMTG_OVERRIDE;
  Steinberg::Vst::ParamValue toNormalized(
      Steinberg::Vst::ParamValue plain) const SMTG_OVERRIDE;

 private:
  ParamMapping mapping_;
  char unit_[16] = {};
};

}  // namespace aud_vst3

#endif  // AUD_VST3_PARAM_HPP
