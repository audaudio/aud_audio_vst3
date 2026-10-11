// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_shell.hpp"

#include <utility>

#include "aud_vst3_plugin.hpp"

namespace aud_vst3 {

// #############################################################################
aud::Json welcomeParams(Plugin& plugin) {
  aud::Json params = aud::Json::ofArray();
  for (const EngineParam& p : plugin.params()) {
    const ParamMapping* m = plugin.mapping(p.id);
    if (m == nullptr) continue;
    aud::Json param = aud::Json::ofObject();
    param.set("id", aud::Json::ofNumber(p.id));
    param.set("nodeId", aud::Json::ofString(p.nodeId));
    param.set("paramId", aud::Json::ofString(p.paramId));
    param.set("node", aud::Json::ofNumber(p.node));
    param.set("index", aud::Json::ofNumber(p.index));
    param.set("name", aud::Json::ofString(p.name));
    param.set("unit", aud::Json::ofString(p.unit));
    param.set("min", aud::Json::ofNumber(p.min));
    param.set("max", aud::Json::ofNumber(p.max));
    param.set("default", aud::Json::ofNumber(p.defaultValue));
    param.set("value",
              aud::Json::ofNumber(m->toPlain(plugin.normalized(p.id))));
    param.set("logarithmic", aud::Json::ofBool(m->logarithmic));
    param.set("steps", aud::Json::ofNumber(m->steps));
    params.push(std::move(param));
  }
  return params;
}

}  // namespace aud_vst3
