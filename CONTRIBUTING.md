# Contributing

Build from the repository root with `bash scripts/build-app.sh`. Run
`BLUEMUSE_LSL_LIBRARY="$PWD/Vendor/lsl.framework/lsl" swift test` before proposing changes.

For decoder or compatibility-timing changes, regenerate fixtures with the C# reference
harness and review the source/fixture differences. Preserve upstream notices and
keep compatibility and smoothing as explicit choices. A passing fixture test is not
proof of real-device timing accuracy.

For hardware reports, include macOS version, CPU architecture, Muse model, settings,
reproduction steps and observed rates. Review logs before sharing them; remove personal
identifiers and recordings. Mark untested headset/OS combinations honestly.
