# Windows / macOS functionality audit — 2026-11-04

The reference is the Windows source supplied in this workspace, principally
`Reference/BlueMuse.App/Misc/Constants.cs`, `MuseManagement`, `Athena`, `Settings`, `Bluetooth`,
`LSL`, `Pages/MainPage.xaml`, and the protocol handler in `App.xaml.cs`.
This is a source and local-execution audit, not a Windows-versus-Mac hardware
certification. A blanket claim of 100% identical behavior is not justified.

## Executed verification

- Compiled the original C# legacy decoders, original numeric bit conversions,
  constants, and Athena decoders unchanged with .NET 9 on this Mac. Only a minimal
  Windows IBuffer type shim was supplied for an unused byte-buffer adapter.
- Generated 1,300 deterministic packet fixtures (18,000 numeric sensor values)
  using those original decoders. Swift matched every value within 1e-9 absolute
  tolerance. Includes five legacy sensor decoders and eight Athena packet tags.
- Ran the original Athena protocol self-check unchanged through the .NET 9 audit
  harness: PASS. The original net8 project could not directly run because only
  .NET 9 is installed; its Program.cs was linked unchanged into the audit harness.
- Swift tests cover boundary values, sign, byte order, channel layout, malformed
  packets, multiplexed Athena packets, control-message reassembly, model profiles,
  settings, secondary timestamp encoding, bounded history, and graph rendering.
- Actual liblsl outlet/inlet tests verify received values and primary timestamps
  for float32 / double64, secondary timestamps off/on, and native MUSE_4CH output.
- LSL XML checks cover manufacturer, device metadata, units, and electrode labels.
- Previously acquired the physical Muse 2's five EEG channels, three accelerometer
  channels, three gyroscope channels, three PPG channels, and four telemetry fields
  over LSL. In a 20-second check: approximately 256.15 / 50.99 / 50.99 / 64.19 /
  0.10 Hz respectively, with zero backwards timestamps. This does not establish
  long-session reliability or quantitative timing accuracy.

The audited build was also checked after a Stop/Start cycle: the application log
confirmed the Bluetooth connection remained open, then streaming resumed without
service rediscovery. A subsequent 12-second LSL check received all five families:
3,072 EEG samples (255.90 Hz), 612 accelerometer and 612 gyroscope samples
(50.98 Hz each), 762 PPG samples (63.48 Hz), and one telemetry update. Every channel
was finite and all streams had zero backwards timestamps. The earlier attempt was
interrupted by a normal Stop, so its receiver correctly reported the closed outlet;
it was not treated as a successful uninterrupted acquisition.

All 18 Swift tests passed; the final control-cycle buffer reset/delay adjustment
also passed the four targeted WindowsParityTests checks.

## Feature mapping

| Reference feature | macOS status and evidence |
| --- | --- |
| Muse 2016 / Muse 2 / Muse S / Athena / Smith support | Implemented; profiles, channels and decoder fixtures tested. Physical Muse 2 tested; other models not physically tested. |
| Legacy EEG TP9, AF7, AF8, TP10, optional Right AUX | Same order, 12-bit centering and 0.48828125 scale; original decoder comparison passed. Muse 2/2016 use five-channel layouts; S/Smith use four. |
| Legacy PPG | Same 3 channels, six unsigned 24-bit samples per packet, nominal 64 Hz and original metadata. |
| Accelerometer / gyroscope | Same signed values, axis order, scales, nominal 52 Hz and 3-sample blocks. |
| Telemetry | Same four fields, battery /512 and second field ×2.2, nominal 0.1 Hz; units now match original `Various`. Original uncertainty about the non-battery fields is retained. |
| Athena EEG / optics / IMU / battery | Matching original values across all eight supported sensor tags; both notification characteristics, prescribed initialization commands and delays implemented. |
| LSL data precision | Both original float32 and double64 options present. |
| Secondary timestamps | Same labels and 1-channel double64 / 2-channel float32 base+remainder representation; real transmission tested. |
| Nominal rates, labels, units, manufacturer, device metadata | Matched to original constants. Audit corrected shortened device descriptions and telemetry units. |
| LSL sample batching / buffering | Matches original chunk settings: legacy 12/3/3/6/1; Athena 4/3/3/1/1; 360-second outlet buffer. MUSE_4CH intentionally uses immediate publication like the Python script. |
| Clock formats | Epoch and both LSL clock selectors available. Both LSL clock selectors now call liblsl directly, matching the current Windows source. Actual sample timestamp construction still differs as described below. |
| Start/stop, first/all/specific headsets, future discovery | UI and original protocol command families implemented; device selectors use names/UUIDs. |
| Stop stream while staying connected | Corrected during audit: an ordinary stop sends halt, closes outlets and unsubscribes sensor notifications while retaining the connection. During an in-flight/failed GATT operation, cancellation may require disconnecting. |
| Explicit Disconnect | Additional macOS control: halt/close/release Bluetooth and suppress automatic reconnection. |
| Device/control info | Same v1/v6 and status commands, periodic refresh while idle, manual refresh. Audit corrected nested/fragmented JSON parsing and added explicit refresh control. |
| Reset | Original reset command available; four-channel output is also closed. |
| All documented sensor/precision/timestamp settings and defaults | Present, persisted and tested. Values are captured at session start, as in Windows. |
| Stream statistics, latest timestamp/values, copy | Present. Added Copy All Stream Info to match the original combined-copy convenience. |
| Logs, log folder, selection, window restoration | Native equivalents implemented. One unique main window verified through repeated URL launches. |
| Simultaneous headsets | Independent sessions and per-device source IDs implemented; multiple physical headsets not tested. |
| Live plots / MUSE_4CH | macOS additions requested by the user; do not remove the normal five sensor outlets. |

## Differences that remain explicit

1. **Bluetooth identity and pairing.** CoreBluetooth uses peripheral UUIDs rather
   than exposing MAC addresses. Exact Windows MAC-based selectors and stream names
   cannot be reproduced using this API. Always Connect is not the Windows setting's
   force-unpair/re-pair operation; pairing is controlled by macOS. Windows-specific
   MSIX installation, PowerShell syntax and Windows Bluetooth recovery instructions
   are replaced by native macOS mechanisms.
2. **Timing behavior.** The app now offers a default Windows-compatible mode and
   optional smoothing. The smoothing mode keeps its tested host-anchored sample-clock fit and
   monotonic packet boundaries. Windows legacy streams backdate each block from
   its own arrival, allowing inter-packet jitter/backwards times. The original
   Athena RLS uses a different covariance update. Legacy Windows telemetry also
   backdates one sample by ten seconds, while Smoothed mode timestamps it at arrival.
   Compatibility mode now reproduces the original assignment rules, including
   legacy telemetry backdating, verified with C# timestamp fixtures. Actual times
   still depend on OS delivery; smoothing-mode per-sample times differ. No claim of equivalent synchronization accuracy
   is made without hardware timing measurements.
3. **Packet-loss handling.** Both preserve EEG channels with NaN backfill; macOS
   also times out incomplete PPG blocks instead of retaining them indefinitely.
   This is an intentional bounded-memory/data-gap behavior difference.
4. **Identity and runtime.** Windows uses the same assembly source ID for its
   outlets; macOS uses distinct per-device/per-sensor IDs. The bundled liblsl is
   macOS universal 1.17.7, not the older Windows DLL. UI, statistics averaging,
   outlet lifecycle during recovery, and OS Bluetooth scheduling are not identical.
5. **Experimental / unverified hardware.** No Windows execution, Intel runtime,
   physical Athena/S/2016/Smith run, simultaneous-headset run, or calibrated
   side-by-side timing test has been performed. Athena is explicitly experimental
   in the supplied Windows README as well.

For the user's Muse 2, the implemented acquisition path provides all of the
Windows sensor families and the same decoded numeric values, plus graphs and the
native four-channel output. This evidence supports functional coverage for the
normal acquisition workflow; it does not certify 100% equivalence or guarantee
that another Bluetooth implementation will have identical reliability.

## Reproduce

```sh
# From the repository root, with .NET 9 installed:
dotnet run --project Tests/BlueMuse.Parity.Tests -- Tests/BlueMuseCoreTests/Fixtures/windows-decoder-fixtures.json
dotnet run --project Tests/BlueMuse.Parity.Tests -p:StartupObject=BlueMuse.Athena.Tests.Program --no-restore
BLUEMUSE_LSL_LIBRARY="$PWD/Vendor/lsl.framework/lsl" swift test 
bash scripts/build-app.sh
```

Reference hashes for this audit:

- `Reference/BlueMuse.App/Misc/Constants.cs`: `0272417a77fe256af7b7118104cd76486de6779a9e5e13e036336409974fdac9`
- `Reference/BlueMuse.App/Athena/AthenaDecoders.cs`: `266cb8f22870356a3d87b10fbf0fc1752e396f8e1bb152cf9c09d4816bd20feb`

The timing-mode selector was added after the initial audit. Compatibility timing is
now tested against 1,000 blocks generated from the original C# timestamp classes.
See TIMING.md for the two modes and exact legacy telemetry behavior.

The publish-ready project subsequently passed 23 Swift tests, including five timing
tests and compatibility comparisons against 1,000 original C# timestamp blocks.
The receiver/CSV example was independently checked with synthetic LSL samples.
