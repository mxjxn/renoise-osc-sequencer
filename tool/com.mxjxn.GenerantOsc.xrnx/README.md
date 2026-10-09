# Generant OSC

Create mappings in **Tools → Generant OSC → Mappings and settings**, then write
their two-character IDs into effect columns on tracks whose names begin with
`[OSC]`.

`01 FF` means mapping `01` with byte value `FF`. Mapping modes decide whether
that byte becomes a trigger, gate, integer, range, enum, or marker.

Automation is read from envelopes on `[OSC]` tracks when the destination
device's display name is `[OSC 01]`, using the corresponding mapping ID.

Use **Tools → Generant OSC → Export Blender score** to write a deterministic
`rack-osc-score` JSON file for OSC Score Bridge.
