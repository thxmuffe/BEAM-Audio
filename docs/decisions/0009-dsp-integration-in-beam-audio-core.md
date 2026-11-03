# 0009 — DSP integration in BEAM Audio repository

Date: 2026-11-02. Status: accepted.

## Decision

Paavo Penttilä made a community architecture decision to **keep the digital signal processors (DSPs), DSP interfaces, and reference processing implementations directly within the `BEAM Audio` repository**, rather than prematurely splitting them into separate repositories.

## Context & Rationale

1. **Early-Stage Velocity**: The OpenSound and BEAM Audio ecosystem is young and undergoing active evolution across spatial contracts, 3D Cartesian coordinate frames, Higher-Order Ambisonics (HOA), and cluster clock presentation targets. Splitting DSP into an external repository at this phase would introduce version-pinning overhead, git submodule friction, and slow down core development.
2. **Headless Completeness**: A standalone speaker node (e.g. a headless Raspberry Pi driving an active cinema monitor) running BEAM Audio must be fully functional out of the box. Colocating basic PEQ, 3D VBAP panners, delay alignment, and crossover DSP within the engine repository ensures that open-source nodes require no secondary installations to play and correct audio.
3. **Stabilization Before Separation**: Keeping DSP in-tree allows rapid, atomic co-evolution of Erlang stream handlers and native SIMD convolution engines. Once the C/Rust DSP Application Binary Interface (ABI) stabilizes, third parties and commercial add-ons may package proprietary or specialized DSP modules independently.

