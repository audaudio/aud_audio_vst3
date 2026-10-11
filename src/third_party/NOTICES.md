# Third-party notices of aud_audio_vst3

`vst3sdk` holds the subset of the VST3 SDK that the plugin and the
validator compile: the translation units the SDK's CMake modules list for
the libraries `base`, `pluginterfaces`, `sdk_common`, `sdk` and
`sdk_hosting` and for the validator (macOS only), the entry points of
`macmain.cpp`, the single-component base class
`vstsinglecomponenteffect.cpp`, and the headers they include. The
manifests are `vst3sdk/SOURCES.txt` (a plugin),
`vst3sdk/VALIDATOR_SOURCES.txt` (the validator) and
`vst3sdk/INCLUDES.txt` (the headers). Source:
https://github.com/steinbergmedia/vst3sdk at tag `v3.8.1_build_84` (`base` fcf9da0, `pluginterfaces` 4f547e8, `public.sdk` 586dc5e),
vendored on 2026-10-09 for ticket 24 by `scripts/vendor-vst3sdk.js`.

| Component | Path | Version | License |
| --- | --- | --- | --- |
| VST 3 SDK | `vst3sdk/base`, `vst3sdk/pluginterfaces`, `vst3sdk/public.sdk` | v3.8.1_build_84 | MIT, `vst3sdk/LICENSE.txt` and the `LICENSE.txt` of each folder |
| json.h | `vst3sdk/public.sdk/source/vst/moduleinfo/json.h` | v3.8.1_build_84 | Unlicense (public domain), header of the file |

The editor app (`editor/`) carries the Flutter engine and framework
(BSD-3-Clause) into the bundles: in `Contents/Helpers` for the variants
A, S and F, in `Contents/Frameworks` for B. `flutter build` writes
their notices and those of every Dart package into the app's
`flutter_assets/NOTICES.Z`, which travels with it. `build-plugin.js`
copies these notices and `vst3sdk/LICENSE.txt` into each bundle's
`Contents/Resources`.

VST is a registered trademark of Steinberg Media Technologies GmbH.
