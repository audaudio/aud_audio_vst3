// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The harness of the native unit tests (scripts/test-native.js), shaped
// after package:test: group() and test() name what runs, an expectation
// that fails reports the names with its file and line, and finish() gives
// the count and the exit code. Header-only, no test framework.

#ifndef AUD_VST3_HARNESS_HPP
#define AUD_VST3_HARNESS_HPP

#include <cmath>
#include <cstdio>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace aud_vst3_test {

// #############################################################################
// The state of the run.
struct TestRun {
  // ...........................................................................
  // The names of the groups and of the test that run.
  std::vector<std::string> names;

  // ...........................................................................
  // The tests that ran and those that failed.
  int tests = 0;
  int failures = 0;

  // ...........................................................................
  // Whether the running test failed.
  bool failed = false;
};

// #############################################################################
// The run of this process.
inline TestRun& testRun() {
  static TestRun run;
  return run;
}

// #############################################################################
// Runs `body` as the group `name`.
inline void group(const std::string& name, const std::function<void()>& body) {
  testRun().names.push_back(name);
  body();
  testRun().names.pop_back();
}

// #############################################################################
// Runs `body` as the test `name`.
inline void test(const std::string& name, const std::function<void()>& body) {
  TestRun& run = testRun();
  run.names.push_back(name);
  run.failed = false;
  body();
  run.tests += 1;
  if (run.failed) run.failures += 1;
  run.names.pop_back();
}

// #############################################################################
// `value` as a failure shows it.
template <typename T>
std::string describe(const T& value) {
  std::ostringstream text;
  text << value;
  return text.str();
}

inline std::string describe(const std::string& value) {
  return "\"" + value + "\"";
}

inline std::string describe(const char* value) {
  return describe(std::string(value));
}

inline std::string describe(bool value) { return value ? "true" : "false"; }

template <typename T>
std::string describe(const std::vector<T>& values) {
  std::string text = "[";
  for (const T& value : values) {
    text += (text.size() > 1 ? ", " : "") + describe(value);
  }
  return text + "]";
}

// #############################################################################
// Fails the running test with `message`, found at `file`:`line`.
inline void fail(const std::string& message, const char* file, int line) {
  TestRun& run = testRun();
  run.failed = true;
  std::string name;
  for (const std::string& part : run.names) {
    name += (name.empty() ? "" : " ") + part;
  }
  std::fprintf(stderr, "FAILED: %s\n  %s:%d: %s\n", name.c_str(), file, line,
               message.c_str());
}

// #############################################################################
// Expects `actual` to equal `expected`.
template <typename T, typename U>
void expectEqual(const T& actual, const U& expected,
                 const char* file = __builtin_FILE(),
                 int line = __builtin_LINE()) {
  if (actual == expected) return;
  fail("expected " + describe(expected) + ", got " + describe(actual), file,
       line);
}

// #############################################################################
// Expects `actual` to differ from `expected` by `tolerance` at most.
inline void expectNear(double actual, double expected, double tolerance,
                       const char* file = __builtin_FILE(),
                       int line = __builtin_LINE()) {
  if (std::fabs(actual - expected) <= tolerance) return;
  fail("expected " + describe(expected) + " within " + describe(tolerance) +
           ", got " + describe(actual),
       file, line);
}

// #############################################################################
// Prints the count of the tests and the failures; the exit code of the
// test: 0 when every test passed.
inline int finish() {
  const TestRun& run = testRun();
  std::printf("%d tests, %d failed\n", run.tests, run.failures);
  return run.failures == 0 ? 0 : 1;
}

}  // namespace aud_vst3_test

#endif  // AUD_VST3_HARNESS_HPP
