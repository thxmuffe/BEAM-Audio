# 0004: Windows audio binding research and trial

Date: 2026-10-30. Status: PortAudio preferred for reusable audio device I/O;
existing Erlang binding rejected after an isolated Windows trial. No production
dependency adopted.

## Scope and decision

Prefer a dedicated audio I/O library, with Erlang owning interpretation, DSP,
metering, routing and buffering/timing policy. A library should reduce our own
binding work, expose useful configuration and timing information, and work with
the current x64 Windows/OTP build. No iOS or Mac app sources were changed.

PortAudio is the strongest reusable audio I/O candidate reviewed. Its established
device/stream API covers capture and rendering, sample formats, rates, channel
counts and latency suggestions without requiring a player or DSP framework.
However, the existing Erlaudio NIF is not suitable as a drop-in dependency. Keep
the working direct WASAPI port for this Windows increment rather than take over
an old binding or introduce a second production backend merely to use a library.
This is a binding decision, not a network media protocol or virtual-driver choice.

## Candidates

| Candidate | Fit and limits | Decision |
| --- | --- | --- |
| [Comet/erl_com](https://erlang.org/documentation/doc-5.1/pdf/comet-1.1.1.pdf) | Reusable COM access, including early-bound interfaces. Located documentation is from the old 32-bit Windows/OTP era; no current x64 implementation was established. | Not a supported drop-in route for this build. |
| [longlene/cffi](https://github.com/longlene/cffi) | Small generic libffi binding with NIF and port modes. Reviewed source uses `dlfcn`/`dlopen`, pthreads and a Unix-oriented build; documented layout is System V AMD64. Generic calls would still need COM interface/vtable and thread-lifetime handling. | Promising experiment, but a Windows port plus COM integration would exceed the present task. |
| [Erlaudio](https://github.com/asonge/erlaudio) with [PortAudio](https://github.com/PortAudio/portaudio) | Existing Erlang device/stream API over dedicated native audio I/O. Binding source last pushed in 2015; Windows build instructions reference obsolete OTP link libraries. | Built and tried; stream opening failed in the isolated VM. Do not integrate this binding. |
| [miniaudio low-level API](https://miniaud.io/docs/manual/) | Configurable capture/render and WASAPI loopback; high-level engine is optional. No ready current Erlang binding was established in this review. It would still require our own native boundary. | Useful alternative, but does not resolve the Erlang binding requirement. |

WASAPI itself is a COM interface, not a socket providing an audio stream.
Generic FFI does not remove native ABI, pointer ownership or COM thread rules.
In particular, [IAudioCaptureClient buffer release](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-releasebuffer)
must occur on the same thread as its corresponding buffer acquisition.

## Reproducible trial and observations

Generated sources and artifacts are isolated under ignored
`builds/intermediates/Windows/audio-library-trial/`. No upstream source was
patched and no dependency was added to the app build.

Pinned sources:

- PortAudio: `1ca0eeedb678c3cca80f3306c474d69a7a4b5278`.
- Erlaudio: `93d4d16fcd4a80cb488a9083405fab37c6b82a05`.
- cffi source review: `50be0947a86f32431d15c6fa12d79d6c88597214`.

Built PortAudio as a Release x64 DLL with WASAPI enabled; ASIO, DirectSound,
WMME, WDM/KS, examples and tests disabled. Built the unmodified Erlaudio C NIF
and Erlang modules against the bundled OTP 29.1.2 headers/runtime, using a manual
link command rather than its obsolete build recipe. This proves source
compilation, not compatibility of its original build tooling.

The isolated BEAM loaded the NIF and enumerated speakers, microphone and two
WASAPI loopback inputs. A stereo float32, 48 kHz, 480-frame stream-open trial
terminated the isolated process with Windows access-violation exit status
`0xC0000005`. A second run printed successful module load and the marker before
stream opening, then terminated without returning a stream-open result. The
exact native fault location was not established with a debugger.

A separate small native PortAudio probe opened the same speaker loopback,
started it, read 480 stereo float32 frames (3,840 bytes) at 48 kHz, and closed
successfully. Five seconds of silent playback supplied loopback activity;
no microphone was opened, no captured audio was saved and device settings were not
changed. This establishes basic PortAudio loopback operation on this laptop,
not sustained capture, low latency, signal fidelity or synchronization.

Source inspection independently found binding defects: an Erlang term result is
stored in a 32-bit `int`, string copies write a terminating byte beyond binaries
allocated with `strlen`, and the capture success path releases a binary after
transferring its ownership with `enif_make_binary`. The latter contradicts the
[OTP binary ownership contract](https://www.erlang.org/doc/apps/erts/erl_nif.html#enif_make_binary).
These are reasons to reject adoption even if a particular run appeared to work;
they are not a debugger-confirmed explanation for this crash.

The binding also hardcodes a native 5 ms polling sleep, sets
`hostApiSpecificStreamInfo` to NULL and sends PCM without the direct WASAPI
bridge's device-position/QPC metadata. Adopting it would therefore require more
than repairing the crash to preserve our configuration and timing needs.

Loopback is present in the pinned PortAudio development source and exposed as
input devices with `[Loopback]` names. Do not substitute the old 19.7.0 release
and assume this functionality exists: upstream documents loopback with the
[19.8 API additions](https://files.portaudio.com/docs/v19-doxydocs/pa__win__wasapi_8h.html).
The pinned build's version string still reports `V19.7.0-devel`; use the commit
identity rather than infer a released version from that string.

## Consequences

The existing 82-line WASAPI helper remains the working input adapter. It already
delegates sample interpretation, metering and polling policy to Erlang and
passes Windows timing metadata. Replacing it with Erlaudio would increase native
code ownership and lose capabilities. A future PortAudio adapter should justify
its thin binding by needed device/output functionality, preserve timing metadata
and expose configuration without moving DSP or policy out of Erlang. No
cross-platform performance claim or measured latency target follows from this
trial. Neither library installs an OS-selectable virtual Parvi audio device.
