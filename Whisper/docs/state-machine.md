# Whisper dictation state machine

Whisper keeps what it is doing in one machine, `WDictationMachine`
(Foundation only), instead of flags.  The record button, the
"Start Recording"/"Stop Recording" menu item (Cmd+R), the status line, the
progress bars and the menu validation are all computed from its state by
`WDViewState` and applied by one `-render`.

## The rule

The microphone opens and closes only on an explicit user action: the record
button, the menu item or its shortcut (all one event, `UserToggle`).

- Only `UserToggle` enters `Recording`, and only from `Ready` or `Error`.
- Only `UserToggle` leaves `Recording` normally, into `Finishing`.
- A system report may end a recording only when it cannot go on:
  `CaptureFailed` (microphone or model did not open) and `DeviceLost` (the
  audio input ended by itself) lead to `Error`, whose status line reads
  "Recording stopped: <why>".
- Silence never stops a recording.  `SilenceHeard`/`SpeechHeard` only switch
  a hint in the status line ("no speech heard, press Stop when done").
- Holding the shortcut or Space on the button does not toggle again: key
  repeats are dropped before they reach the machine (`WApplication` with
  `WKeyRepeatFilter`; the X11 backend never sets `isARepeat`, so a repeat
  is a key-down of a key not released since, or one with the time of its
  last key-up).
- Live typing of the text never goes into Whisper's own window: there a
  typed space pressed the focused record button and stopped (or started) a
  recording by itself.  When the window active at the start of a take is
  Whisper's, or its owner cannot be told, the text is only shown in
  Whisper.

## States

| State | Meaning |
|---|---|
| Ready | Nothing running, microphone closed. Status shows the last result ("Done", "No speech detected") or "Ready". |
| Downloading | A model is being downloaded; nothing can be recorded yet. |
| Recording | Microphone open, started by the user. |
| Finishing | The user stopped; the final pass over the whole take runs. |
| Transcribing | An audio file is being transcribed. |
| Error | The last job failed; microphone closed; the reason is shown. Behaves like Ready otherwise. |

## Events

User: `UserToggle`, `UserTranscribeFile`, `UserDownloadModel`.

System (each tagged with the generation of the job that sends it):
`LaunchDownloadModel`, `CaptureFailed`, `DeviceLost`, `SilenceHeard`,
`SpeechHeard`, `FinishDone`, `FinishFailed`, `FileDone`, `FileFailed`,
`DownloadDone`, `DownloadFailed`.

## Transition table

Cell = target state (effects); `-` = declared ignore (the reason is in the
table in `WDictationMachine.m`, the test checks every ignore has one).
A target equal to its row is an internal transition.  Regenerate with
`PRINT_TABLE=1 ./obj/t_WDictationMachine` in `Tests/Unit`.

| State \ Event | UserToggle | UserTranscribeFile | UserDownloadModel | LaunchDownloadModel | CaptureFailed | DeviceLost | SilenceHeard | SpeechHeard | FinishDone | FinishFailed | FileDone | FileFailed | DownloadDone | DownloadFailed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Ready | Recording (start capture) | Transcribing (transcribe file) | Downloading (download) | Downloading (download) | - | - | - | - | - | - | - | - | - | - |
| Downloading | - | - | - | - | - | - | - | - | - | - | - | - | Ready | Error |
| Recording | Finishing (stop and finish) | - | - | - | Error (cancel capture) | Error (cancel capture) | Recording | Recording | - | - | - | - | - | - |
| Finishing | - | - | - | - | - | - | - | - | Ready (deliver text) | Error | - | - | - | - |
| Transcribing | - | - | - | - | - | - | - | - | - | - | Ready (deliver text) | Error | - | - |
| Error | Recording (start capture) | Transcribing (transcribe file) | Downloading (download) | Downloading (download) | - | - | - | - | - | - | - | - | - | - |

## Generations and threads

Transitions happen on the main thread only.  Entering `Recording`,
`Transcribing` or `Downloading` starts a new generation; every report of a
worker (streamed segments, chunk results, progress, the final pass, the
download) carries the generation it was started with, and the machine drops
events of an older generation (`WDOutcomeStale`).  So a late result of take
1 can neither stop take 2 nor add text to it.

All whisper.cpp work runs on one serial `NSOperationQueue`, because a
context allows one `whisper_full` at a time; the final pass of a take is
queued behind a chunk that is still running instead of being skipped.

Events raised by effects (a capture that does not open) are queued and
handled after the transition that caused them; alerts (offer to download a
missing model) are shown after the state is rendered, never inside a
transition.

## Tests

- `Tests/Unit/t_WDictationMachine`: every state x event pair is decided;
  no system event enters `Recording`; only the toggle, `CaptureFailed` and
  `DeviceLost` leave it, the latter two into `Error`; only the toggle opens
  the microphone; stale generations change nothing; 100 silent chunks keep
  recording.
- `Tests/Unit/t_WKeyRepeatFilter`: a held key toggles once, also when
  the backend passes on the key-up of a repeat pair.
- `Tests/Unit/t_WDictationViewState`: the record control says "Stop"
  exactly while recording, is enabled exactly where the toggle does
  something, and the status texts.

Build with `gmake` in `Tests/Unit`, run `./obj/t_*`.

## Testing without a microphone

`defaults write Whisper CaptureDevice <device>` makes Whisper open that
input instead of the one chosen in Sound (an ALSA PCM name, or an OSS
device path).  An ALSA `file` PCM whose `infile` is a FIFO fed in real time
by `ffmpeg -re -f lavfi -i anoisesrc ...` (or `anullsrc` for silence) gives
a paced test input; killing Whisper's `ffmpeg` capture child simulates a
lost device.
