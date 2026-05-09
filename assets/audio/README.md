# Audio Assets

Runtime layout:

- `sfx/ui/`: short interface feedback cues.
- `sfx/gameplay/`: build, portal, resource, and action feedback cues.
- `sfx/units/`: unit weapon, hit, and movement cues.
- `music/`: longer music loops, kept compressed as OGG.
- `ambience/`: looping or background ambience, kept compressed as OGG.
- `licenses/`: license files bundled with imported asset packs.

The current runtime audio engine loads WAV files directly. Short effects are exported as 44.1 kHz, mono, 16-bit PCM WAV. Music and ambience keep their OGG originals in the tree, with WAV runtime copies beside them until an OGG streaming decoder is added.

See `CREDITS_AUDIO.md` for source and license details.
