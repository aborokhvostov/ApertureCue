# Third-party notices and dependency review

Review date: 25 October 2026. This inventory describes the checked-in source and native build configuration. It is not a license grant for third-party SDKs that may be added later.

## Original project

Copyright (C) 2026 ApertureCue contributors. The original ApertureCue sources, project documentation, tests, embedded Metal shader and generated demo assets are `GPL-3.0-or-later`, except where an individual file explicitly states otherwise. The complete GPLv3 text is in [LICENSE](LICENSE); the “or later” selection is made by the repository's license notice, not by changing the canonical GPL text.

## Current runtime and build inventory

| Component | Use | License / distribution treatment |
|---|---|---|
| Swift compiler, standard library and open source core libraries | Build tools and Swift language/runtime facilities | Official Swift project: Apache License 2.0 with Runtime Library Exception. The exception permits redistribution of compiler-embedded portions without the attribution otherwise required by specified Apache sections. No Swift source or standalone toolchain is copied into this repository. |
| Foundation on macOS | Data, JSON, URLs, threading and filesystem | macOS system framework. The Apple implementation is supplied by the operating system, not relicensed as GPL or Apache by this project. |
| AppKit, UniformTypeIdentifiers | Native desktop windows, controls, panels and document types | macOS system frameworks; not bundled. |
| Metal and MetalKit | GPU API, drawable views and texture loader | macOS system frameworks; not bundled. The project's Metal shader was authored for ApertureCue. |
| AVFoundation, CoreVideo, QuartzCore | Video/audio playback, pixel buffers, Metal texture bridge and clock | macOS system frameworks; not bundled. Codec availability is determined by the installed operating system. |
| CoreMIDI | Optional MIDI input adapter | macOS system framework; not bundled. |
| Darwin/libSystem | POSIX UDP sockets and process/memory primitives | Operating-system libraries, not copied. Individual Darwin source components have their own licenses; this project does not incorporate their source. |
| XCTest | Standard SwiftPM test harness where installed | Build/test environment component; not linked into the application. The direct fallback assertion runner in `Tests/Runner` is original project code. |
| `MappingCore` dynamic library | Original model, geometry, project store and protocol codecs | ApertureCue's own code, `GPL-3.0-or-later`; packaged beside the executable. |

There are no third-party Swift package dependencies, Qt libraries, FFmpeg libraries, downloaded shader libraries or external media libraries bundled by the current native build. Merely accepting a movie filename does not make unsupported AVFoundation codecs available.

## Compatibility basis and boundaries

The [official Swift license](https://www.swift.org/LICENSE.txt) and [Swift project overview](https://www.swift.org/about/) identify Apache-2.0 with the Runtime Library Exception. GNU's [license compatibility list](https://www.gnu.org/licenses/license-list.html#apache2) identifies Apache-2.0 as compatible with GPLv3. This supports the selected GPLv3-or-later license for the original application; the exception does not convert all Apple frameworks to open source.

The native app links the frameworks already supplied with macOS. Its corresponding-source inventory excludes those operating-system components under the System Libraries provisions of [GPLv3 section 1](https://www.gnu.org/licenses/gpl-3.0.en.html#section1). The build does not redistribute the Apple SDK or system frameworks. Apple developer tools/SDK use remains governed by the applicable [Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf), linked from [Apple's agreements page](https://developer.apple.com/support/terms/). An App Store release, notarization service or other channel must be assessed for that channel's additional terms; none is implied by this source release.

No additional GPL linking exception has been introduced for optional proprietary integrations. Adding an in-process SDK requires a new compatibility and redistribution review before distributing the combined build. An optional-module directory alone does not resolve licensing compatibility.

## Optional integrations not included

Syphon, Spout, NDI, Blackmagic, Canon SDKs, depth-camera SDKs, USB-DMX vendor libraries, Ableton Link, PJLink libraries, laser DAC SDKs and MiniMad software are not shipped. Each future adapter must record the exact source/version, license, dynamic/static linking, redistribution conditions and test hardware. A codec protocol implemented from a public specification does not include a vendor's implementation or establish hardware certification.

## Art-Net protocol credit and registration

The official [Art-Net 4 specification, revision 1.4dp, 23 October 2025](https://art-net.org.uk/downloads/art-net.pdf) permits royalty-free protocol use, requires a user-guide credit and requires manufacturers implementing it to apply for an OEM code. The prescribed credit is reproduced in [the user guide](docs/user-guide.md#protocol-credits). ApertureCue's code was written independently; the protocol document and vendor SDK are not redistributed or relicensed as project source.

OEM status: **no ApertureCue OEM code is assigned or claimed; no registration application has been submitted**. The [official OEM listing/application page](https://art-net.org.uk/oem-code-zone/#apply-for-oem-code) did not list ApertureCue at this review. Do not invent or reuse another product's code. Registration and the unimplemented discovery/management requirements remain release-conformance work; tested ArtDmx data packets alone are not full Art-Net 4 conformance.

sACN is specified by ESTA's ANSI E1.31. The checked IPv4 data-packet subset should not be advertised as current full-standard compliance: the [official published-document listing](https://tsp.esta.org/tsp/documents/published_docs.php) now identifies E1.31-2025 as current and 2018 as superseded. The publicly indexed [2018 text](https://tsp.esta.org/tsp/documents/docs/ANSI_E1-31-2018.pdf), section 9.1.1, establishes destination-port behavior; no source-port obligation is inferred from Art-Net. Full review of the 2025 text remains pending because the official download requires sign-in. No address was submitted and no standards PDF is bundled.

## Demonstration content and reference material

`DemoGenerator.swift` creates the calibration PNG and animated MOV mathematically from original code. The demo uses no stock photography, paid media, MadMapper material-library resources or user project content. System fonts and native widgets are obtained from the operating system and their files are not copied into the app.

MadMapper documentation and product names are cited for research. Their prose, screenshots, proprietary formats and assets are not licensed by this repository's GPL notice. Temporary research downloads are outside the repository. The canonical GPLv3 license document is reproduced under the permission stated in that document.

## CI services

The CI configuration references official `actions/checkout` and `actions/upload-artifact` by verified commit IDs, plus the official Swift Docker image. Those tools execute in the build service and are not part of the application bundle. The [Swift Docker installation page](https://www.swift.org/install/linux/docker/) identifies the official image source. Their versions and runner images should be recorded in each build log.
