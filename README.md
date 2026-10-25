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
├── allParametric                  # main entry point
├── core/
│   ├── ui.sh                       # console formatting helpers
│   ├── config.sh                   # paramDict reader
│   ├── utils.sh                    # modes, append index, core count
│   ├── mesh.sh                     # gmsh parameter replacement
│   ├── physics.sh                  # calculationScript replacement
│   ├── solver.sh                   # Allrun wrapper and timing
│   ├── archive.sh                  # result archiving
│   ├── database.sh                 # CSV consolidation
│   ├── cases.sh                    # case-matrix generation
│   ├── status.sh                   # status files and dashboard
│   ├── runDetails.sh               # timing, logging, summary
│   ├── parallel.sh                 # parallel case scheduler
│   └── coreScreening.sh            # core-scaling study
├── testCase/
│   ├── Allrun                      # entry point; sources the two below
│   ├── AllrunSimple                # all plain case commands
│   ├── Allclean
│   ├── calculationScript
│   ├── 0/
│   ├── constant/
│   ├── Mesh/
│   └── system/
└── Archive/
```

---

## 2. Quick start

```bash
cd "$FOAM_SRC/solutionMonitoring/parametricStudy"

# Run with automatic backup of previous results
./allParametric testCase

# Explicit modes
./allParametric testCase --backup
./allParametric testCase --delete
./allParametric testCase --append
```

The case directory is resolved to an absolute path before the controller changes
into it, so background workers can always reach the base case.

### Case-run files

| File | Purpose |
|---|---|
| `testCase/Allrun` | Entry point; includes `AllrunSimple` and `core/runDetails.sh` |
| `testCase/AllrunSimple` | Plain OpenFOAM commands in one editable block; run this to check the case |
| `core/runDetails.sh` | Timing, log diversion, and summary |

`allParametric` exports `PARAMETRIC_CORE_DIR`, so `Allrun` can find
`core/runDetails.sh` both in the base case and inside worker directories.

To check a case before submitting it to a parametric study:

```bash
cd testCase
./AllrunSimple
```

This prints the mesh, decomposition, solver, and reconstruction output directly,
with no timing wrapper.  All OpenFOAM commands are in the marked
`OPENFOAM COMMANDS` block, so you can add or reorder lines without changing the
runner.

To run the same case with the compact summary:

```bash
./Allrun
```

Full command output is written to `log.Allrun`.

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
continueFromPrevious false;            // true = chain serially from previous result

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
- Duplicate parameter combinations are skipped with a warning before a case is
  registered, except when `continueFromPrevious true`.
- `continueFromPrevious true`:
  - forces one case at a time;
  - skips duplicate detection, because hysteresis paths revisit the same values;
  - uses the previous archived case as the next starting point;
  - renames the previous latest time directory to `0` and removes its `uniform`
    folder, so `controlDict` needs no changes;
  - keeps the mesh unchanged throughout the study;
  - stops the chain if a case fails and marks the remaining cases as `SKIPPED`.
- `continueFromPrevious` is not compatible with `coreScreening` or
  `gridIndependence`.

### Chained/hysteresis example

```foam
continueFromPrevious true;

parameters (M T);

sets
(
    (10 30)   // start from base 0
    (15 30)   // increase
    (20 30)   // increase
    (15 30)   // decrease
    (10 30)   // decrease
);
```

Each case after the first starts from the previous archived case.  The previous
latest time directory becomes the new `0` (with `uniform` removed), so the existing
`controlDict` `startTime`/`endTime` values are reused without modification.  The
mesh is kept from the previous case.

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
10. Remove the temporary `calculationScript.backup`; archived results are kept.

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
├── Allrun
└── AllrunSimple
```

The scheduler:

- copies the base case into the worker directory using reflink copies when the
  filesystem supports them;
- skips `constant/polyMesh` and `Mesh/*.msh`, because the mesh is rebuilt from
  the `.geo` source anyway;
- removes any stale `constant/polyMesh` in normal runs; chained runs keep the
  previous mesh;
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
│       ├── log.Allrun                # full mesh/decompose/solve log
│       └── log.Allrun.<caseName>      # compact run summary
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
| `ui_fit` | Truncate text to a column width |
| `ui_debug` | Debug message, only when `DEBUG=1` |

Colours are enabled only for interactive terminals and can be disabled with:

```bash
NO_COLOR=1 ./allParametric testCase
```

The rule width is detected from the terminal and can be overridden with:

```bash
UI_WIDTH=100 ./allParametric testCase
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

A status snapshot is written to:

```text
parametricStatus/dashboard.txt
```

It is written once at the end of the study as plain text without ANSI colour
codes, then copied to `paramDatabase/status.txt` and the temporary status
directory is removed.  The file starts with a settings summary from
`system/paramDict`, including `continueFromPrevious`, solver, study type, case
prefix, parameters, cores, and execution mode.

The final table shows parameters, cores per case, state, and elapsed time:

```text
  Case           Parameters   State     Elapsed
  ----------------------------------------------------------------
  c0R6v1         M=10 T=30    DONE      00:00:49
  c0R6v2         M=20 T=100   DONE      00:01:03
  c0R6v3         M=30 T=3     SKIPPED   --
  ----------------------------------------------------------------
  Summary        Done: 2   Running: 0   Failed: 0
                 Queued: 0   Skipped: 1
  Total elapsed  00:01:52
```

There is no live percentage, progress bar, or ETA.  A case prints
`Finished <case> in <elapsed>` when it completes, so the order of completed
cases is visible.  Failed cases also record the failing step, for example
`reconstruct (rc=1)`.

The final summary adds:

- passed / failed counts;
- wall time;
- aggregate case time;
- core utilization percentage;
- fastest and slowest cases.

After completion, the final board is preserved as:

```text
paramDatabase/status.txt
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
cd "$FOAM_SRC/solutionMonitoring/parametricStudy"

for f in allParametric core/*.sh \
         testCase/Allrun testCase/AllrunSimple; do
    bash -n "$f" || echo "FAIL $f"
done

cd "$FOAM_SRC/solutionMonitoring"
git diff --check -- parametricStudy
```

### 9.3 Test on a throwaway copy

```bash
rm -rf /tmp/opencode/testCase-run
cp -a "$FOAM_SRC/solutionMonitoring/parametricStudy/testCase" /tmp/opencode/testCase-run

cd "$FOAM_SRC/solutionMonitoring/parametricStudy"
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
