# BEAM-Audio artwork

`beam-audio.png` (1024 × 1024, transparent) and `beam-audio.svg` are the canonical
artwork supplied by the user on 2026-11-10. Their original contents are preserved.
Earlier logo designs have been removed from the current source tree.

OpenSound remains the commercial product name. It uses this BEAM-Audio logo for
its app icons and in-app branding, with “Powered by BEAM-Audio” where space allows.
Sharing artwork does not rename products, Device identities or wire protocols.
Other product UI/assets remain in OpenSound. Artwork ownership/trademark and
redistribution terms are separate from the runtime's code licence; no new terms
are assigned by moving these supplied files here.

Product builders resolve this directory through `BEAM_AUDIO_ROOT`, defaulting to
the sibling checkout. Web packages copy both originals into their generated
output. Native formats are derived from the PNG: macOS/Windows preserve its
transparency; iOS app icons use an opaque dark-green background as required by
the platform. See OpenSound's shared branding README for regeneration commands.
