# Provenance and adaptation

This project is derived from https://github.com/kowalej/BlueMuse, a Windows Muse-to-LSL
application. The source snapshot was supplied locally; its exact upstream commit was
not recorded. `Reference/UPSTREAM.json` records hashes of the reference files used here.

The macOS adaptation rewrites the UI and Bluetooth integration in SwiftUI/CoreBluetooth,
ports the original legacy/Athena decoding and timestamp rules, and adds optional
smoothing, graphs, explicit disconnection and native MUSE_4CH output.

The unchanged C# files under `Reference/` are kept to make numeric/timestamp comparisons
reproducible. The test harness supplies only a minimal Windows buffer type shim for an
unused byte-buffer adapter; it does not replace the original numeric conversion code.
The upstream Athena self-check is linked unchanged into that harness.

The derivative retains GPL-3.0. All upstream copyrights and applicable notices remain
with their respective authors. liblsl is a separately licensed dependency; its archive
source, checksum and license text are in Vendor/NOTICE.md and Vendor/LICENSE-liblsl.txt.

This source has no dependency on the original author's GitHub account, signing keys,
Windows packages, DLLs or installation scripts. No private recordings, session logs,
Bluetooth identifiers or local Python environment are required for publication.

The native four-channel output and minimal receiver example use public Muse electrode
labels and standard LSL APIs. The distribution contains no classifier model, training
dataset, subject records or experiment-specific analysis protocol.
