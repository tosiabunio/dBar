# dBar

A macOS menu bar app that shows a real-time stereo level meter for everything your Mac is playing.

Click the speaker icon in the menu bar to open the meter:

- **L / R bars**: peak level in dBFS (IEC 60268-18 scale). Green is below −12 dB, yellow is −12 to −3 dB, red is above −3 dB.
- **Peak hold**: a single lit segment marks the recent peak. The number on the right is that value in dB.
- **Clip indicator**: latches red when a channel reaches 0 dBFS. **Reset Clip** clears it.
- **Launch at Login**: starts dBar when you log in. It uses `SMAppService`, so it appears under System Settings › General › Login Items. Turn it on from the copy of the app you'll keep using, ideally one in `/Applications`.

## Requirements

- macOS 14.2 or later (uses Core Audio process taps)
- Xcode 16 or later

## Build and run

Open `dBar.xcodeproj` and press Run, or build from the terminal:

```sh
xcodebuild -project dBar.xcodeproj -target dBar -configuration Release build SYMROOT=$PWD/build
open build/Release/dBar.app
```

## Permission

The first time you open the meter, macOS asks for permission to capture system audio. If you denied it, or the meter stays silent while audio is playing, enable dBar under
**System Settings › Privacy & Security › Screen & System Audio Recording** (in the *System Audio Recording Only* section).

The build is ad-hoc signed ("Sign to Run Locally"). macOS may ask for permission again after a rebuild. To avoid that, set your development team under *Signing & Capabilities*.

## How it works

- `SystemAudioTap` creates a global stereo-mixdown process tap (`CATapDescription(stereoGlobalTapButExcludeProcesses: [])`) and wraps it in a private aggregate device. The aggregate's IO callback measures per-channel peaks with vDSP.
- `LevelMeterModel` drains those peaks 60 times a second and applies meter ballistics: instant attack, 24 dB/s release, 1.5 s peak hold.
- Per-app volume mixers that play other apps' audio back themselves (currently FineTune) are left out of the tap. Otherwise that audio would be counted twice and read about 6 dB too high.
- Capture runs only while the popover is open, so the app uses no CPU and shows no recording indicator otherwise.

The meter shows the digital signal apps send to the output, measured before the system volume control. Changing the volume slider does not move the bars.

## License

[BSD Zero Clause License (0BSD)](LICENSE). You can use, copy, modify and distribute dBar for any purpose, with or without credit.
