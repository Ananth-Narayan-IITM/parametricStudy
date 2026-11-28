# Test cases

This directory contains two runnable examples:

```text
testCase/
├── openfoam/   # host OpenFOAM example
└── container/  # daFoamContainer example
```

## Host OpenFOAM example

`testCase/openfoam` is the original EHD OpenFOAM case with `coarse` and `fine`
tags.

```bash
./allParametric testCase/openfoam --delete
```

It is configured for one local node by default.  Add SSH nodes in
`testCase/openfoam/system/nodes.conf` and set `distributed true` in
`testCase/openfoam/system/paramDict` for multi-node host execution.

## Container example

`testCase/container` is a reduced DAFoam topology-optimization case based on
`h0R20v58`–`h0R20v63`.

Changes from the original:

- mesh reduced from 90 × 180 to 20 × 40
- `nContinuation` reduced from 100 to 5
- six T cases: `0 20 50 100 300 400`
- `workerRuntime container`
- `tagMerge true`

Run it inside `daFoamContainer` from a copy of the engine under the mounted
DAFoam source, for example:

```bash
cd /home/dafoamuser/mount/parametricStudy
./allParametric testCase/container --delete
```

The engine and case must be inside `/home/dafoamuser/mount`, because that is the
only host directory mounted into the container.

The container runtime compiles the mounted DAFoam source once per worker and once
for the local master container with:

```bash
. /home/dafoamuser/dafoam/loadDAFoam.sh
cd /home/dafoamuser/mount
./Allmake
```

`testCase/container/system/nodes.conf` starts with only the local container node.
Uncomment the `taylor` entry to add a remote container worker.

The case uses the custom DAFoam solver `ehdFoam_b4R11` through `runScript.py`.
That solver must exist after `./Allmake` inside the container.

## Verification helper

To verify the distributed execution path with a lightweight case:

```bash
./testMultiNode --nodes-file testCase/openfoam/system/nodes.conf
```

For container workers:

```bash
./testMultiNode --runtime container \
    --case-source testCase/container \
    --nodes-file testCase/container/system/nodes.conf
```

`testMultiNode` replaces the real solver with a short node-reporting run, so it
does not test the production solver itself.
