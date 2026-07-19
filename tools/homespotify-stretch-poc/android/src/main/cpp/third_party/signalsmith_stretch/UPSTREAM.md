# Signalsmith Stretch upstream provenance

This directory is reserved for a minimal, pinned vendor copy used only by the
isolated HomeSpotify Stretch POC. Gradle and the application never download
these sources automatically.

## Pinned components

| Component | Version | Exact commit | Official source | License |
| --- | --- | --- | --- | --- |
| Signalsmith Stretch | Header version 1.3.2 | `57b93f4e9206a089a45387eaa39bdc9f310d3308` | <https://signalsmith-audio.co.uk/code/stretch.git>, official mirror <https://github.com/Signalsmith-Audio/signalsmith-stretch> | MIT |
| Signalsmith Linear | 0.3.1 | `5668673560146a9cfe38c25315071e3fd68c8317` | <https://git.signalsmith-audio.co.uk/Signalsmith-Audio/linear.git>, official mirror <https://github.com/Signalsmith-Audio/linear> | MIT |

The Stretch repository has no corresponding GitHub release for 1.3.2. The
version above is the version declared by the header at the pinned commit. It
must therefore be described as a commit-pinned upstream version, not as a
published release.

The historical Git servers can advertise a commit while omitting one of its
tree objects. The vendor script therefore retries only against the official
`Signalsmith-Audio` GitHub mirrors. The exact commit check remains mandatory,
and the generated manifest records the upstream which supplied the checkout.

## Minimal vendor layout

The manual vendor script copies only:

- `signalsmith-stretch.h`;
- `signalsmith-linear/stft.h`;
- `signalsmith-linear/fft.h`;
- the MIT license from each upstream repository.

The copyright and permission notices must remain distributed with substantial
copies of the software. `VENDOR_MANIFEST.json`, generated locally by the
manual script, records a SHA-256 for every copied file. The template in this
directory intentionally contains no invented hashes.

Run `tool/vendor_signalsmith.ps1` explicitly from a network-enabled developer
environment. Review the exact checkout and generated manifest before committing
the vendored sources. Runtime and Gradle downloads are prohibited.

No Android or production-readiness claim follows from vendoring the headers.
NDK compilation, fixture processing, audio review and device profiling remain
separate validation gates.
