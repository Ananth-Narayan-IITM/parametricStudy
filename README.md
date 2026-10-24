# OpenFOAM Parametric Study Engine

This directory contains the controller and supporting modules for running
OpenFOAM parametric studies, grid-independence studies, and core-scaling
studies.  The current version also supports **multiple cases running at the same
time**, limited by the number of available cores and the number of cores requested
per case.

---

## 1. Directory layout

```text
parametricStudy/
├── allParametric/
│   ├── allParametric              # main entry point
│   ├── core/
│   │   ├── ui.sh                  # console formatting helpers
│   │   ├── config.sh              # paramDict reader
│   │   ├── utils.sh               # modes, append index, core count
│   │   ├── mesh.sh                # gmsh parameter replacement
│   │   ├── physics.sh             # calculationScript replacement
│   │   ├── solver.sh              # Allrun wrapper and timing
│   │   ├── archive.sh             # result archiving
│   │   ├── database.sh            # CSV consolidation
│   │   ├── cases.sh               # case-matrix generation
│   │   ├── parallel.sh            # parallel case scheduler
│   │   └── coreScreening.sh       # core-scaling study
│   └── testCase/
│       ├── Allrun                   # mesh + solver + reconstruction
│       ├── Allclean
│       ├── calculationScript
│       ├── 0/
│       ├── constant/
│       ├── Mesh/
│       └── system/
└── Archive/
```

---

## 2. Quick start

```bash
cd "$FOAM_SRC/solutionMonitoring/parametricStudy/allParametric"

# Run with automatic backup of previous results
./allParametric ../testCase

# Explicit modes
./allParametric ../testCase --backup
./allParametric ../testCase --delete
./allParametric ../testCase --append
```

The case directory is resolved to an absolute path before the controller changes
into it, so background workers can always reach the base case.

---

## 3. `system/paramDict` reference

```foam
solver              ehdFoam_b2R4;
studyType           parametricStudy;   // parametricStudy | gridIndependence
prefix              c0R6v;
processors          8;                // cores per case

coreScreening       false;
coreList            (1 2 4 6 8 12);
coreEffMin          0.8;

availableCores      24;               // total cores on the machine
maxConcurrentCases  auto;             // auto | positive integer
statusRefresh        1;               // dashboard refresh interval (s), 0 disables live refresh

meshFile            "Mesh/c0R6.geo";
meshOut             "Mesh/c0R6_OF.msh";

runComment          "Check";
runTag              "new revision";
authorNote          "Sweeping data";

parameters          (M T);            // parametricStudy
// meshParameters   (Nx Ny);           // gridIndependence

M                   (10 10 30);
T                   (10 3 6);

sets
(
    (10 30)
    (20 100)
);
```

### Scheduling rules

- `maxConcurrentCases auto` computes:

  ```text
  maxParallel = min(totalCases, availableCores / processors)
  ```

- An explicit `maxConcurrentCases` must satisfy:

  ```text
  maxConcurrentCases * processors <= availableCores
  ```

- `coreScreening true` runs the core list sequentially and exits before the
  parametric matrix is generated.

---

## 4. Execution flow

1. Resolve `CASE_DIR` to an absolute path.
2. Load `paramDict`.
3. Handle existing results according to `--delete`, `--append`, or `--backup`.
4. Validate the core budget.
5. Run core screening if enabled; otherwise set the per-case core count.
6. Detect the append start index.
7. Generate the case matrix only.
8. Run the matrix through the parallel scheduler.
9. Consolidate the derived database.
10. Clean the base case and remove temporary backups.

---

## 5. Parallel case scheduler

Each case receives its own isolated working copy:

```text
parametricWork/<caseName>/
```

A case starts as soon as a slot is free.  It does not wait for a whole batch.

Per case:

```text
parametricWork/<caseName>/
├── 0/
├── constant/
├── Mesh/
├── system/
├── calculationScript
└── Allrun
```

The scheduler:

- copies the base case into the worker directory;
- removes any stale `constant/polyMesh`;
- replaces the parameter values in the worker `calculationScript`;
- writes the derived `transportProperties` into the base `paramDatabase`;
- runs `Allrun` with `NP=processors`;
- copies timing metadata back to the base `parametricLogs`;
- archives the result into `parametricStudy/<caseName>`;
- removes the worker directory on success;
- keeps the worker directory on failure for debugging.

On success, `parametricWork`, `parametricLogs`, and `parametricStatus` are removed.
On failure, the failed workspace is preserved and the worker log is copied into the
archived case directory.

---

## 6. Output layout

```text
testCase/
├── paramDatabase/
│   ├── <caseName>.txt             # derived transportProperties
│   ├── <caseName>_mesh.txt         # grid-independence mesh values
│   ├── paramTable.csv             # consolidated study table
│   └── status.txt                 # final static status board
├── parametricStudy/
│   └── <caseName>/                # archived case
│       ├── 0/
│       ├── constant/
│       ├── system/
│       ├── Mesh/
│       ├── <time directories>/
│       ├── calculationScript
│       └── log.Allrun.<caseName>
└── coreScalingLogs/                # core-screening runs
```

---

## 7. Console UI module

`core/ui.sh` provides consistent console formatting:

| Helper | Purpose |
|---|---|
| `ui_banner` | Title banner with optional subtitle |
| `ui_section` | Section heading with rule |
| `ui_info` | Informational message |
| `ui_ok` | Success message |
| `ui_warn` | Warning message |
| `ui_error` | Failure message |
| `ui_kv` | Aligned key/value line |
| `ui_case` | Aligned case-matrix line |
| `ui_debug` | Debug message, only when `DEBUG=1` |

Colours are enabled only for interactive terminals and can be disabled with:

```bash
NO_COLOR=1 ./allParametric ../testCase
```

The rule width can be changed with:

```bash
UI_WIDTH=80 ./allParametric ../testCase
```

---

## 8. Case status dashboard

Every case has a status file:

```text
parametricStatus/<caseName>.status
```

The file contains:

```text
state=QUEUED|RUNNING|DONE|FAILED
start=<epoch>
end=<epoch>
elapsed=<seconds>
rc=<exit code>
```

A static dashboard is written to:

```text
parametricStatus/dashboard.txt
```

During a run it shows:

```text
  Case           State      Elapsed
  ------------------------------------------------------------
  c0R6v1         DONE       00:00:49
  c0R6v2         RUNNING    00:00:21
  c0R6v3         QUEUED     --
  ------------------------------------------------------------
  Summary        Done: 1    Running: 1
  Failed         0          Queued: 1
  Total elapsed  00:01:10
```

The dashboard shows only elapsed time.  It does not estimate a finish time.

After completion, the final board is preserved as:

```text
paramDatabase/status.txt
```

### Smooth refresh

On an interactive terminal, the dashboard refreshes in place every
`statusRefresh` seconds.  It moves the cursor back over the previous table,
clears each line, and rewrites the table.  There is no full-screen clear, so the
output does not flicker.

Set `statusRefresh 0` to disable live refresh.  Disable live refresh but keep
the final board with:

```bash
STATUS_LIVE=0 ./allParametric ../testCase
```

Disable only the in-place redraw while keeping periodic refresh with:

```bash
STATUS_REDRAW=0 ./allParametric ../testCase
```

## 9. Reproducing the changes

### 9.1 Restore a clean test case

```bash
cd "$FOAM_SRC/solutionMonitoring/parametricStudy/testCase"

rm -rf constant/fluid \
       parametricLogs parametricStatus parametricWork \
       c0R6v1.txt c0R6v2.txt calculationScript.backup

git checkout -- 0/alphat 0/p Mesh/c0R6_OF.msh
```

### 9.2 Verify syntax

```bash
cd "$FOAM_SRC/solutionMonitoring/parametricStudy/allParametric"

for f in allParametric core/*.sh; do
    bash -n "$f" || echo "FAIL $f"
done

cd "$FOAM_SRC/solutionMonitoring"
git diff --check -- parametricStudy
```

### 9.3 Test on a throwaway copy

```bash
rm -rf /tmp/opencode/testCase-run
cp -a "$FOAM_SRC/solutionMonitoring/parametricStudy/testCase" /tmp/opencode/testCase-run

cd "$FOAM_SRC/solutionMonitoring/parametricStudy/allParametric"
./allParametric /tmp/opencode/testCase-run --delete
```

### 9.4 Check the result

```bash
cat /tmp/opencode/testCase-run/paramDatabase/paramTable.csv
find /tmp/opencode/testCase-run/parametricStudy -maxdepth 2 -type d
```

---

## 10. Notes

- `availableCores` is machine-specific.  Set it to the number of cores you want
  the scheduler to use, not necessarily `nproc`.
- `processors` is the number of MPI ranks per case.  It must not exceed
  `availableCores`.
- If `maxConcurrentCases` is `auto`, the scheduler uses as many cases as the
  core budget allows.
- For OpenMPI, concurrent cases use:

  ```bash
  OMPI_MCA_hwloc_base_binding_policy=none
  ```

  so that MPI ranks can be distributed over all available cores.  Other MPI
  implementations ignore this variable.
- Old results are never deleted implicitly in `--backup` mode.  They are moved to
  `[backupN]paramDatabase` and `[backupN]parametricStudy`.
- `--append` continues the case numbering from the highest existing
  `<prefix><number>` directory.
- `reconstructPar` is skipped when the solver has not written any non-zero time
  directory, avoiding a false “No times selected” failure.
- Scientific-notation time directories such as `1e-4` are archived correctly.
