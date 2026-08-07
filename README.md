# FFmpegBuild

**Goal of this repository: produce FFmpeg NuGet packages.**

It builds FFmpeg **shared** libraries and tools for Windows, Linux and Android, in **4 license variants**
(GPL-3 / LGPL-3 / GPL-2 / LGPL-2.1) and 9 FFmpeg versions, then packs every combination into NuGet packages
that a .NET or C++ project can consume with a single `PackageReference`. The compiled archives are also
published on GitHub Releases, but the packages are the deliverable — everything else here (the docker build
matrix, the Android NDK pipeline, the packager) exists to produce them.

- NuGet packages: search `TqkLibrary.FFmpeg` on [nuget.org](https://www.nuget.org/packages?q=TqkLibrary.FFmpeg)
- Raw build archives: <https://github.com/tqk2811/FFmpegBuild/releases>

Pipeline in one line:

```
FFmpeg sources ──► docker matrix (desktop) / NDK pipeline (Android) ──► artifacts*/*.zip|.tar.xz
                                                                              │
                                                            AutoPackager ─────┴──► Packages/*.nupkg ──► nuget.org
```

Desktop builds use the [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) docker harness (kept as a
pristine submodule + a tracked overlay of local customizations); Android builds use a custom NDK pipeline in
[`android/`](android/).

---

## 0. Using the packages

Reference the `Native` package for the libraries, and the `Tools` package if you also need the
`ffmpeg`/`ffprobe`/`ffplay` executables (`ffplay` is absent on Android and on Linux `*2` builds):

```xml
<ItemGroup>
  <PackageReference Include="TqkLibrary.FFmpeg.Lgpl3.Native.Win.x64" Version="8.1.2.21" />
  <PackageReference Include="TqkLibrary.FFmpeg.Lgpl3.Tools.Win.x64"  Version="8.1.2.21" />
</ItemGroup>
```

Pick the ID that matches your license choice, target OS and architecture (see the matrix below), and take
the version from nuget.org — the version encodes which FFmpeg release the binaries came from
(see [How package versions are built](#how-package-versions-are-built)). Each package carries its own
README describing exactly what it ships.

---

## 1. The package matrix

### Package ID scheme

```
TqkLibrary.FFmpeg.{Gpl3|Lgpl3|Gpl2|Lgpl2}.{Native|Tools}.{Win|Linux|Android}.{x64|x86|arm64}
```

| Segment | Values | Meaning |
|---|---|---|
| License | `Gpl3`, `Lgpl3`, `Gpl2`, `Lgpl2` | `*3` = built with `--enable-version3` (GPL-3.0-or-later / LGPL-3.0-or-later); `*2` = GPL-2.0-or-later / LGPL-2.1-or-later |
| Kind | `Native`, `Tools` | `Native` = shared libraries (+ headers, + import libs on Windows); `Tools` = `ffmpeg`/`ffplay`/`ffprobe` executables, depends on the matching `Native` package (exact version) |
| Target | `Win.x64`, `Win.x86`, `Win.arm64`, `Linux.x64`, `Linux.arm64`, `Android.arm64`, `Android.x64` | maps to RIDs `win-x64`, `win-x86`, `win-arm64`, `linux-x64`, `linux-arm64`, `android-arm64`, `android-x64` |

Binaries always ship under `runtimes/<rid>/native/`:

- **.NET SDK-style projects** resolve them automatically when the build/publish RID matches
  (e.g. `dotnet publish -r linux-x64`).
- **.NET Framework projects** get them copied next to the output by the bundled MSBuild targets
  (`build/<id>.targets`).
- **C++ (MSBuild) projects** consuming the `Native` package get `include/` on the compiler include path
  and, on Windows, the import libraries on the linker line (`build/native/<id>.targets`).
- **.NET for Android (MAUI / Xamarin.Android)** bundles the `.so` into `lib/<abi>/` of the APK/AAB.

### How package versions are built

The package version is **derived from the upstream build tag**, not chosen by hand:

```
ffmpeg-n8.1.2-21-gce3c09c101-win64-gpl-shared-8.1.zip   ──►   8.1.2.21
        └────┘ └┘                                             └────┘ └┘
      base version  commit count since the release tag
```

So a package version is `<FFmpeg base version>.<commits since that release tag>` — e.g. FFmpeg 8.1.2 with
21 commits on top becomes `8.1.2.21`. Rebuilding the same FFmpeg branch later picks up newer commits and
yields a higher fourth component, which is exactly how updates are shipped.

Two consequences:

- The fourth component is **not** a package revision you can bump freely — it comes from the source.
- Desktop and Android versions of the *same* FFmpeg release can differ slightly when the two pipelines
  checked out the release branch at different commits.

For the versions actually available for a given package ID, query nuget.org:
`https://api.nuget.org/v3-flatcontainer/<lowercase-package-id>/index.json`

### Coverage

Snapshot of the published build round (FFmpeg 4.4 → 8.1, i.e. 9 release branches):

- **Desktop:** 9 versions × 4 licenses × 5 platforms = 180 combos, **172 built**.
  The 8 missing ones are `win32` (x86) for FFmpeg **6.1** and **5.0** — see [Known limitations](#5-known-limitations).
- **Android:** 9 versions × 4 licenses × 2 ABIs = **72 built** (arm64-v8a, x86_64; API 21, NDK r26d).
- **NuGet:** 172×2 = 344 desktop + 72×2 = 144 Android = **488 packages** published.

A later build round adds newer FFmpeg branches and/or higher fourth components; nuget.org is the
authoritative list.

---

## 2. Repository layout

| Path | Purpose |
|---|---|
| [`FFmpeg-Builds/`](FFmpeg-Builds) | Submodule → BtbN/FFmpeg-Builds, kept **pristine** (no local edits) |
| [`overlay/`](overlay/) | All local customizations, mirroring the submodule tree; copied onto it at build time |
| [`apply-overlay.sh`](apply-overlay.sh) | Copies `overlay/` into the submodule (called automatically by the build scripts) |
| [`RunOvernight.sh`](RunOvernight.sh) | Desktop driver: full matrix loop, resumable, per-combo cleanup, runtime-adjustable deadline |
| [`set-deadline.sh`](set-deadline.sh) | Changes the deadline of an **already running** `RunOvernight.sh` |
| [`BuildFFmpeg.sh`](BuildFFmpeg.sh) | Simpler desktop loop (no deadline / logging), useful for one-off combos |
| [`android/build-libs.sh`](android/build-libs.sh) | Android NDK pipeline: ~21 external libs per ABI, then FFmpeg per version × license × ABI |
| [`android/build_arm64.sh`](android/build_arm64.sh) | Minimal single-combo Android configure/build (reference / smoke test) |
| [`AutoPackager/`](AutoPackager/) | .NET 10 console app: archives → per-combo nuspec/props/targets/README → `nuget pack` |
| [`*.nuspec`, `*.props`, `*.targets`](.) | Package templates the AutoPackager expands per combo |
| [`RunPackNuget.ps1`](RunPackNuget.ps1) / [`RunPackNugetAndroid.ps1`](RunPackNugetAndroid.ps1) | Desktop / Android packaging entry points |
| [`PushNuget.ps1`](PushNuget.ps1) | Copies to a local feed (`$env:localNuget`) and pushes to nuget.org (`$env:nugetKey`) |
| [`RunTests.ps1`](RunTests.ps1), [`TestProjects/`](TestProjects/) | Local consumption tests (C# SDK-style, .NET Framework, C++/MSBuild) |

Git-ignored working folders: `artifacts/` (desktop archives), `artifacts-android/`, `TempOutput*/`,
`Packages/` (generated `.nupkg`), `logs/`, `deadline.conf`.

---

## 3. Building

### 3.1 Desktop (Windows + Linux targets)

Requirements: Linux host (or VM) with **bash + docker**, ~50 GB free disk, ≥ 11 GB RAM.

```bash
git submodule update --init
./RunOvernight.sh                      # full matrix, newest version first
VERSIONS="8.1 8.0" PLATFORMS="win64 linux64" VARIANTS="gpl-shared" ./RunOvernight.sh
NO_DEADLINE=1 ./RunOvernight.sh        # ignore the stop-hour cutoff
```

Environment knobs: `VERSIONS`, `VARIANTS` (`lgpl-shared gpl-shared gpl2-shared lgpl2-shared`),
`PLATFORMS` (`win64 win32 winarm64 linux64 linuxarm64`), `STOP_HOUR` (default 8), `TZONE`
(default `Asia/Ho_Chi_Minh`), `NO_DEADLINE`, `DEADLINE_FILE`.

Behaviour worth knowing:

- **Resumable** — a combo whose archive already exists in `artifacts/` is skipped.
- **Deadline** — no *new* combo starts after the cutoff; the running one always finishes. The cutoff is
  re-read from `deadline.conf` before every combo, so `./set-deadline.sh 06:30` (or `off`, or an epoch)
  retargets a running build without restarting it.
- **RAM safety** — the overlay sets buildkit `max-parallelism=1`, caps `nproc`, and sets `ENV CORES=2`
  for the `base-winarm64` image (the llvm-mingw/ninja LLVM build ignores the `nproc` cap and otherwise OOMs).
- **Cleanup** — after each combo the combo image, its buildx cache and dangling images are pruned; base
  images and cross-toolchains are kept.

The overlay carries the local customizations:

- `variants/{plat}-{gpl2,lgpl2}-shared.sh` + `defaults-{gpl2,lgpl2}*.sh` — the **v2 license variants**
  (no `--enable-version3`), which upstream does not provide.
- `scripts.d/*` — guards that disable version3-only or license-incompatible deps for v2 variants
  (gmp, opencore-amr, libaribb24, openssl and its dependents srt/libssh/libcurl/libaribcaption/pulseaudio,
  plus sdl2 on Linux).
- `images/base*/Dockerfile` — RAM caps and a pre-seeded `linux-4.18.20` kernel tarball (kernel.org removed
  the v4.x tarballs that crosstool-ng expects).

### 3.2 Android

Requirements: Linux host, **NDK r26d** at `~/android/ndk/android-ndk-r26d` (plus **r27d** used only for a
16 KB-page-aligned `libc++_shared.so`), nasm/meson/ninja. Work dir `~/android-ffbuild`.

```bash
./build-libs.sh libs                                   # external libs only, both ABIs
./build-libs.sh phase2 8.1 8.0 7.1 7.0 6.1 6.0 5.1 5.0 4.4   # version × 4 licenses × 2 ABIs
ANDROID_ABIS="arm64-v8a" DEADLINE_EPOCH=0 ./build-libs.sh ffmpeg gpl
```

Resumable and unattended-safe: an external lib that fails to build is recorded and dropped from the FFmpeg
configure line instead of aborting the run; combos whose artifact already exists are skipped.
API level 21, `--disable-vulkan` (the NDK sysroot's Vulkan headers break older FFmpeg), `--disable-ffplay`
(no SDL/display), shared libs aligned for 16 KB pages (Android 15+).

Edit the Android scripts **in this repo** and copy them to the build machine — not the other way around.

---

## 4. Packaging & publishing

```powershell
.\RunPackNuget.ps1          # wipes Packages\, packs artifacts\        -> 2 nupkg per archive
.\RunPackNugetAndroid.ps1   # additive, packs artifacts-android\       -> 2 nupkg per archive
.\RunTests.ps1                            # full consumption matrix
.\RunTests.ps1 -Rids win-x64,linux-x64    # only selected RIDs
.\PushNuget.ps1             # local feed + nuget.org push (interactive confirmations)
```

`AutoPackager` (net10.0, needs `nuget.exe` on `PATH`) does, per archive:
parse the tag → version/arch/license → extract → generate `README.md`, `.props`, `.targets`
(managed + C++ variants) and both nuspecs → `nuget pack` into `Packages/`.

Linux note: archives extracted on Windows lose symlinks, so the packager **renames the versioned binary to
its SONAME** (`libavcodec.so.62.11.103` → `libavcodec.so.62`) and drops the dangling bare `.so`, which is
what the loader actually needs at runtime. Linking against these on Linux therefore needs
`-l:libavcodec.so.62`-style flags (or a locally created `.so` symlink).

Pushing to nuget.org happens per file with `-SkipDuplicate`; nuget.org enforces a push quota
(HTTP 403 “Quota Exceeded” with a retry-after) when uploading hundreds of packages in one go.

---

## 5. Known limitations

- **win32 (x86) is unavailable for FFmpeg 6.1 and 5.0.** Both fail to compile 32-bit Vulkan code
  (non-dispatchable handles are `uint64_t` but are cast through 32-bit pointers): 6.1 breaks at
  `libavfilter/vsrc_testsrc_vulkan.c`, 5.0 at `libavfilter/vulkan.o`. 4.4, 5.1, 6.0, 7.x and 8.x build fine
  on win32. Fixing this needs a source patch, not a retry.
- **`Gpl2` / `Lgpl2` variants have OpenSSL disabled** (Apache-2.0 is incompatible with GPL-2.0 / LGPL-2.1),
  together with everything that links it: srt, libssh, libcurl, libaribcaption, pulseaudio. On **Linux**,
  sdl2 depends on pulseaudio in this chain, so Linux v2 builds also have **no `ffplay`**.
- **Android `Tools` packages ship raw ELF executables** (`ffmpeg`, `ffprobe`, no `lib*.so` name), so a stock
  non-rooted device will not execute them straight out of the APK. They are meant for `adb push` + `chmod +x`,
  rooted devices, or apps that copy them to their own executable-permitted directory. For in-app media
  processing, call the shared libraries from the `Native` package instead.
- Android ABIs are limited to **arm64-v8a** and **x86_64** (no `armeabi-v7a`, no 32-bit `x86`).
- macOS targets are not built.

---

## 6. License

FFmpeg is free software; redistributing these binaries carries the obligations of the variant you pick —
in particular, linking against a **GPL** build places your application under the GPL. Use an **`Lgpl*`**
variant if your application must stay under a different license. Each package embeds the matching license
text as `docs/LICENSE.txt`.

The scripts and packaging code in this repository are provided as-is; the FFmpeg binaries they produce are
covered by their respective FFmpeg licenses.
