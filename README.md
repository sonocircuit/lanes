# lanes
lanes is a midi looper

record incoming midi notes or load a midi file to up to 7 lanes.
output midi to any midi device or play internally via nb.

----

### quickstart:

**norns:**

- E1: select lane
- E2 / E3: change parameter
- K2 / K3: navigate pages
- hold K1: display options/shift
- shift + K2 / K3: select options

- goto parameters/edit > global settings to change the quantization options.
  

**grid:**

- rows 1-7: lanes
- row 8: mod keys
  - key 1: `rec`
  - key 2: `playback`
  - keys 5-12: `snapshots`
  - key 15: `reset`
  - key 16: `all` / `metro viz`

- press a lane key to start playback. press a lane key to change position. press and hold a lane key and press and release a second lane key to set a loop.
- hold `rec` and a lane key to enable recording. press a lane key to disable recording. while recording hold `reset`and a lane key to undo the last recording.
- hold `playback`and press a lane key to stop playback. press again to resume. hold `playback` and press `all` to stop all
- press an empty `snapshot` key to save a snapshot (playing tracks & loops). hold `reset` and a `snapshot` key to clear.
- hold `reset` and a lane key to reset the playback position. hold `reset` and press `all` to reset all playhead positions.

**midi files:**

- midi files live under `dust/code/lanes/midi_files/`
- add midi files via smb. load to a lane via UI.
- file naming convention is: `my_filename_xxb.mid` xx represents the number of beats to auto-set the length (optional).

