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

# Or run from inside the case directory
cd testCase
../allParametric --delete

# Or add the engine to PATH automatically
./allParametric --export
source ~/.bashrc
cd /path/to/case
allParametric --delete

# Explicit modes
./allParametric testCase --backup
./allParametric testCase --delete
./allParametric testCase --append
```

`--export` adds the real engine directory to `~/.bashrc` automatically for future
shells.  To update only the current shell, use:

```bash
source ./allParametric --export
```

That does **not** modify your shell startup file.  If you prefer to do it manually:

```bash
export PATH="/path/to/parametricStudy:$PATH"
```

Then:

```bash
cd /path/to/any/case
allParametric --delete
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

Full command output is written to a log outside the case directory when run
through the engine, so a case `Allclean` script cannot delete it.  The archived
case keeps it as `log.Allrun.full`.  Standalone `./Allrun` writes
`log.Allrun.full` in the case directory.

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
logTimeZone          Asia/Kolkata;     // IST by default; UTC, Europe/London, ...

meshFile            "Mesh/c0R6.geo";
meshOut             "Mesh/c0R6_OF.msh";

// user, IP, SSH origin, and node are recorded automatically at run time.
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
  - copies missing run scripts (`preProcessing`, `updateRunScript`,
    `runScript*.py`, `0.orig`) from the base case if an older archive lacks
    them;
  - skips duplicate detection, because hysteresis paths revisit the same values;
  - uses the previous archived case as the next starting point;
  - renames the previous latest time directory to `0` and removes its `uniform`
    folder, so `controlDict` needs no changes;
  - keeps the mesh unchanged throughout the study;
  - replaces `0.orig` with the seeded `0`, so `preProcessing` can still run its
    normal `Allclean` + `restore0Dir` sequence and restore the previous solution
    (removing `0.orig` alone would not work, because `Allclean` removes `0`);
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
│   ├── caseMatrix.csv             # authoritative case parameter values
│   ├── paramTable.csv             # metadata + case parameters + script constants
│   ├── status.txt                 # final static status board
│   └── run.log                    # completion events with end times
├── parametricStudy/
│   └── <caseName>/                # archived case
│       ├── 0/
│       ├── constant/
│       ├── system/
│       ├── Mesh/
│       ├── <time directories>/
│       ├── calculationScript
│       ├── log.Allrun.full           # full command output
│       └── log.Allrun.<caseName>      # compact run summary
└── coreScalingLogs/                # core-screening runs
```

`paramTable.csv` columns are:

```text
caseName, studyType, runTag, runComment, authorNote,
node, user, ip, sshIp, identitySource,
startTime, endTime, elapsedTime (s), status, reason, exitCode,
<paramDict parameters>,
<resolved calculationScript values excluding paramDict parameters>
```

The per-case transport-property `.txt` dumps are no longer produced.

`status` is `DONE`, `FAILED`, `SKIPPED`, or `UNKNOWN`.  `reason` contains the
failure description, and `exitCode` keeps the exact process exit code.  Common
codes are shown in the failure footnote at the end of a run.

`runTag`, `runComment`, `authorNote`, and the execution identity are stored per
case.  When a case is archived, its `system/paramDict` keeps the metadata used at
run time, and `paramTable.csv` reads those values for the row.  Appending a new
batch therefore does not rewrite the metadata of earlier cases.

The execution identity is derived automatically, so there is no `node` entry to
mistype in `paramDict`:

| Column | Meaning |
|---|---|
| `node` | `user@ip` of the execution machine |
| `user` | user that ran the case |
| `ip` | IP of the machine that actually executed the case |
| `sshIp` | IP of the machine the user connected from; empty for a local run |
| `identitySource` | `local`, `host-env`, or `container` |

`identitySource` is the source category, not the node name.  The node name is in
the `node` column.  Pass `PARAMETRIC_HOST_NODE` to set it explicitly.
`sshIp` is the connection origin, while `node` is the machine that actually
executed the case.  Only the IP is recorded; no username or reverse lookup is
used.

These values are written into each case workspace before the run, archived with
the case, and then copied into `paramTable.csv`.  A run aborts with a clear error
if the user or execution IP cannot be determined.  Unusual environments can
override the detection:

```bash
# Host identity passed into a container
export PARAMETRIC_HOST_USER=...
export PARAMETRIC_HOST_IP=...
export PARAMETRIC_HOST_NODE=...

# Override detected values on the current machine
export PARAMETRIC_USER=...
export PARAMETRIC_NODE_IP=...
export PARAMETRIC_SSH_IP=...
export PARAMETRIC_NODE=...        # alias for PARAMETRIC_HOST_NODE
```

### Running inside Docker

A container cannot see the host login name or LAN IP by default.  It would
otherwise record something like `dafoamuser@172.17.0.2` instead of
`taylor@10.21.153.233`.

Evaluate the host identity before starting the container:

```bash
docker run --rm -it \
    -e PARAMETRIC_HOST_USER="$(id -un)" \
    -e PARAMETRIC_HOST_IP="$(hostname -I | awk '{print $1}')" \
    -e PARAMETRIC_HOST_NODE="$(hostname)" \
    -e SSH_CONNECTION="$SSH_CONNECTION" \
    -e SSH_CLIENT="$SSH_CLIENT" \
    -v "$PWD":"$PWD" -w "$PWD" \
    <image>
```

These variables are evaluated on the host, not inside the container, so the
result table records the host identity with `identitySource=host-env`.  If you
SSH into `taylor` from `poisson`, the result is:

```text
User             taylor
Node             taylor
IP               10.21.153.233
SSH from         10.21.154.47
Identity source  host-env
```

`Node` is the machine that ran the case.  `SSH from` is the IP of the machine
you connected from.  Outside Docker, `SSH_CONNECTION` is already present in the
shell and is read automatically.

Only the IP is recorded; the origin username and host name are not stored.  Use
the IP to identify the connection origin when needed.

This is deliberately the only container mapping mechanism: it is explicit and
unambiguous.  A CSV table keyed by the container user cannot distinguish hosts
when every container runs as `dafoamuser`.

If the host identity is not passed, `allParametric` warns and records the
container identity with `identitySource=container`, so the run is not silently
mislabelled as the host.

Older tables without these columns remain readable.  Their identity fields stay
blank rather than being guessed; newly appended cases get the automatic values.

This also allows several batches with different comments or execution nodes to
live in one case directory:

```bash
# batch 1
allParametric --delete
# edit runComment/runTag in system/paramDict
# batch 2
allParametric --append
```

### Command-line options

```bash
allParametric --help
allParametric --delete       # or -d
allParametric --append       # or -a
allParametric --backup       # or -b
allParametric --rerun <case...>   # or -r
allParametric --case <caseName>    # or -c
allParametric --clean        # or -x; asks before deleting main data folders
allParametric --clean --yes  # no confirmation
allParametric --save-on-failure  # or -s; write partial results automatically
allParametric --export       # add this directory to PATH
```

### Inspect a case

```bash
allParametric --case h0R20v8
# or
allParametric -c h0R20v8
```

### Failed cases

If any case fails, the run stops with a summary and keeps the work directory for
debugging.  It then asks:

```text
Write results to paramDatabase and clean temporary files? [y/N]:
```

The default is `N`.  Answer `y` to:

- write the partial results, including failed cases, to `paramDatabase`;
- include `status`, `reason`, and `exitCode` in `paramTable.csv`;
- remove `parametricWork`, `parametricLogs`, and `parametricStatus`.

For non-interactive jobs, use:

```bash
allParametric --save-on-failure
```

At the end of a failed run, a footnote explains the common exit codes and points
to the per-case log.

### Clean generated data

```bash
allParametric --clean
# or
allParametric -x
```

`--clean` removes:

- `parametricWork/`
- `parametricLogs/`
- `parametricStatus/`
- `coreScalingLogs/`
- `calculationScript.backup`
- leftover `<prefix><number>.txt` files

It asks for confirmation before deleting:

- `parametricStudy/`
- `paramDatabase/`

Default answer is `N`.  Use `--clean --yes` for non-interactive cleanup.

This works for running and finished cases and shows:

- state, start/finish time, and elapsed time
- a `Show log? [Y/n]` prompt, defaulting to yes
- for running cases, the last 20 log lines followed live (`Ctrl-C` to stop)
- after the log ends or is interrupted with `Ctrl-C`, the case values and details
  are printed
- `paramDict` values from `caseMatrix.csv`
- resolved `calculationScript` values
- archive/work directory
- full log, summary log, worker log paths
- the last 20 log lines

### Rerun selected cases

`caseMatrix.csv` is the reliable input source for reruns:

```text
caseName,M,T
h0R20v8,49,0
h0R20v9,49,20
```

Rerun one or more cases from the base case:

```bash
cd /path/to/case
allParametric --rerun h0R20v8 h0R20v9
# or
allParametric -r h0R20v8 h0R20v9
```

The rerun:

- reads the original values from `caseMatrix.csv`
- runs only those cases, from the base case
- replaces `parametricStudy/<case>`
- updates that case's row in `paramTable.csv`
- leaves all other cases untouched

For existing studies without `caseMatrix.csv`, the engine tries to create it from
`paramTable.csv`. This works when every parameter name appears as a column in the
old table.

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
codes, then appended to `paramDatabase/status.txt` and the temporary status
directory is removed.  Existing entries are kept, so the file accumulates the
history of runs; each new snapshot is preceded by a separator and an appended
timestamp.  The file starts with a settings summary from
`system/paramDict`, including `continueFromPrevious`, solver, study type, case
prefix, parameters, cores, execution mode, and `logTimeZone`.  Wall-clock log
times default to `Asia/Kolkata` (IST) and can be changed with `logTimeZone` in
`paramDict` or `LOG_TIMEZONE` in the environment.

The final table shows parameters, cores per case, state, and elapsed time:

```text
  Case           Parameters   State     Elapsed   Finished
  ----------------------------------------------------------------
  c0R6v1         M=10 T=30    DONE      00:00:49  05:32:29
  c0R6v2         M=20 T=100   DONE      00:01:03  05:32:43
  c0R6v3         M=30 T=3     SKIPPED   --        --
  ----------------------------------------------------------------
  Summary        Done: 2   Running: 0   Failed: 0
                 Queued: 0   Skipped: 1
  Total elapsed  00:01:52
```

There is no live percentage, progress bar, or ETA.  A case prints
an update when each case completes, including the wall-clock end time, the
currently running cases, and the queued cases:

```text
[ OK ] Completed h0R19v1 at 2026-11-13 12:34:56  (00:05:32)
  Running              h0R19v2
  Queue                h0R19v3, h0R19v4
```

The same update is appended to `parametricLogs/run.log` and preserved as
`paramDatabase/run.log`.  Failed cases also record the failing step, for example
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

Each run appends its snapshot instead of replacing the file, so earlier run
status boards remain available.  `allParametric --case` reads the latest
snapshot for a case.

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
