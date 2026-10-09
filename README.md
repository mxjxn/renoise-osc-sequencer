# Generant OSC for Renoise

A Renoise tool for writing OSC events in pattern effect columns and exporting
the arrangement as an OSC Score Bridge JSON score. Pairs tightly with [Generant](https://mxjxn.github.io/Generant) and [OSC Score Bridge](https://mxjxn.github.io/osc-score-bridge)

## Install

Run:

```sh
./scripts/package.sh
```

Open the resulting `dist/Generant-Osc-Renoise.xrnx` in Renoise. The tool is
available under **Tools → Generant OSC**.

## Pattern events

Create a track whose name begins with `[OSC]`. A pattern entry such as `01 FF`
invokes mapping `01` with the byte value `FF`. Mappings define the destination,
OSC address, value conversion, fixed arguments, and optional trigger release.
They are stored in the `.xrns` song.

## Automation

On an `[OSC]` track, rename the device behind an automation envelope to
`[OSC 10]`. The tool reads that envelope through mapping `10`. Automation is
sampled at the rate selected in the tool settings.

## Related projects

- [Generant](https://github.com/mxjxn/Generant) receives transport, pattern, and device commands.
- [OSC Score Bridge](https://github.com/mxjxn/osc-score-bridge) receives live OSC in Blender and bakes exported scores.

Detailed instructions are in [the documentation site](docs/index.html).

