// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_param.hpp"

#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <string>
#include <vector>

#include "aud_audio_graph.h"

#include "aud_vst3_harness.hpp"

using aud_vst3::EngineParam;
using aud_vst3::ParamMapping;
using aud_vst3_test::expectEqual;
using aud_vst3_test::expectNear;
using aud_vst3_test::group;
using aud_vst3_test::test;

namespace {

// A normalized value and the plain value it maps to.
struct Case {
  double normalized;
  double plain;
};

using Cases = std::initializer_list<Case>;

}  // namespace

int main() {
  // The mapping of a parameter from `min` to `max` with `flags` and
  // `steps`, as the plugin makes it.
  const auto mappingOf = [](uint32_t flags, float min, float max,
                            uint32_t steps) {
    EngineParam param;
    param.id = 7;
    param.min = min;
    param.max = max;
    param.flags = flags;
    param.steps = steps;
    return ParamMapping::of(param);
  };
  const ParamMapping linear = mappingOf(0, -10, 30, 0);
  const ParamMapping logarithmic =
      mappingOf(AUD_PARAM_LOGARITHMIC, 20, 20000, 0);
  const ParamMapping stepped = mappingOf(AUD_PARAM_STEPPED, 0, 4, 5);

  group("ParamMapping", [&] {
    group("of(param)", [&] {
      test("takes the id and the range", [&] {
        const std::vector<double> taken = {static_cast<double>(linear.id),
                                           linear.min, linear.max};
        expectEqual(taken, std::vector<double>{7, -10, 30});
      });

      test("maps linearly without flags", [&] {
        expectEqual(linear.logarithmic, false);
        expectEqual(linear.steps, 0u);
      });

      test("maps logarithmically with AUD_PARAM_LOGARITHMIC", [&] {
        expectEqual(logarithmic.logarithmic, true);
      });

      for (const float min : {0.0f, -1.0f}) {
        test("maps linearly with AUD_PARAM_LOGARITHMIC from " +
                 std::to_string(min),
             [&] {
               expectEqual(
                   mappingOf(AUD_PARAM_LOGARITHMIC, min, 1, 0).logarithmic,
                   false);
             });
      }

      test("keeps the steps of AUD_PARAM_STEPPED", [&] {
        expectEqual(stepped.steps, 5u);
      });

      for (const uint32_t steps : {0u, 1u}) {
        test("is continuous with AUD_PARAM_STEPPED and " +
                 std::to_string(steps) + " steps",
             [&] {
               expectEqual(mappingOf(AUD_PARAM_STEPPED, 0, 4, steps).steps,
                           0u);
             });
      }

      test("ignores the steps without AUD_PARAM_STEPPED", [&] {
        expectEqual(mappingOf(0, 0, 4, 5).steps, 0u);
      });
    });

    group("toPlain(normalized)", [&] {
      for (const Case& c : Cases{{0, -10}, {0.25, 0}, {1, 30}}) {
        test("maps " + std::to_string(c.normalized) + " linearly to " +
                 std::to_string(c.plain),
             [&] { expectNear(linear.toPlain(c.normalized), c.plain, 1e-4); });
      }

      for (const Case& c :
           Cases{{0, 20}, {0.5, std::sqrt(20.0 * 20000)}, {1, 20000}}) {
        test("maps " + std::to_string(c.normalized) + " logarithmically to " +
                 std::to_string(c.plain),
             [&] {
               expectNear(logarithmic.toPlain(c.normalized), c.plain, 1e-2);
             });
      }

      for (const Case& c : Cases{{0, 0}, {0.3, 1}, {0.4, 2}, {1, 4}}) {
        test("snaps " + std::to_string(c.normalized) + " to step " +
                 std::to_string(c.plain),
             [&] {
               expectEqual(static_cast<double>(stepped.toPlain(c.normalized)),
                           c.plain);
             });
      }

      for (const Case& c : Cases{{-0.5, -10}, {1.5, 30}}) {
        test("clamps " + std::to_string(c.normalized) + " to " +
                 std::to_string(c.plain),
             [&] {
               expectEqual(static_cast<double>(linear.toPlain(c.normalized)),
                           c.plain);
             });
      }
    });

    group("toNormalized(plain)", [&] {
      test("maps linearly", [&] {
        expectNear(linear.toNormalized(0), 0.25, 1e-9);
      });

      test("maps logarithmically", [&] {
        expectNear(logarithmic.toNormalized(2000), 2.0 / 3, 1e-6);
      });

      test("maps a step to its place in the range", [&] {
        expectNear(stepped.toNormalized(3), 0.75, 1e-9);
      });

      for (const Case& c : Cases{{0, -20}, {1, 40}}) {
        test("clamps " + std::to_string(c.plain) + " to " +
                 std::to_string(c.normalized),
             [&] {
               expectEqual(linear.toNormalized(static_cast<float>(c.plain)),
                           c.normalized);
             });
      }

      test("maps an empty range to 0", [&] {
        expectEqual(mappingOf(0, 5, 5, 0).toNormalized(5), 0.0);
      });
    });

    group("toNormalized(toPlain(normalized))", [&] {
      for (const double normalized : {0.0, 0.25, 0.5, 0.75, 1.0}) {
        const std::string value = std::to_string(normalized);
        test("returns " + value + " linearly", [&] {
          expectNear(linear.toNormalized(linear.toPlain(normalized)),
                     normalized, 1e-6);
        });
        test("returns " + value + " logarithmically", [&] {
          expectNear(
              logarithmic.toNormalized(logarithmic.toPlain(normalized)),
              normalized, 1e-6);
        });
        test("returns " + value + " stepped", [&] {
          expectNear(stepped.toNormalized(stepped.toPlain(normalized)),
                     normalized, 1e-9);
        });
      }
    });
  });
  return aud_vst3_test::finish();
}
