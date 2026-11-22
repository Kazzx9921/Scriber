# Sound cues

`cue-start.mp3` and `cue-stop.mp3` are the default start and stop sounds of
[VoiceInk](https://github.com/Beingpax/VoiceInk) (`VoiceInk/Resources/Sounds/sound5.mp3`
and `sound6.mp3`, commit b5d1be9a7c73), used unmodified.

VoiceInk is licensed under the GNU General Public License v3.0:
https://github.com/Beingpax/VoiceInk/blob/main/LICENSE

These two files remain under that license. Anyone redistributing the macOS app with them
included must comply with GPL-3.0 for the combined work. To ship under a different license,
replace them with sounds you own or that carry a compatible license (the app loads whatever
`cue-start` / `cue-stop` audio file is in this folder; `Mac/Tools/make-sound-cues.py` can
synthesize replacements).
