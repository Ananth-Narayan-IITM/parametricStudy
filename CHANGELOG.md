# Changelog

## 2026-10-24 — UI and efficiency improvements

### UI

- Status table now shows:
  - parameters per case;
  - cores per case;
  - `QUEUED`, `RUNNING`, `DONE`, or `FAILED` state with colour;
  - elapsed time and per-case progress;
  - overall progress, ETA, and total elapsed time.
- `run_all_cases` now prints a `Current / Staged / Ran` plan and a final
  `Sweep summary` with wall time, aggregate case time, core utilization, and
  fastest/slowest cases.
- Terminal width is detected automatically and the table collapses the cores
  column on narrow terminals.
- Added `ui_bar` and `ui_fit` helpers.
- Live refresh now prints a compact status line by default.  This avoids leaving
  an old `QUEUED` table behind when the terminal cannot redraw in place.
- `STATUS_REDRAW=1` switches live refresh back to the full table.
- ANSI colour and cursor handling are only enabled when `tput colors` reports a
  colour terminal.

### Efficiency

- Status files are read once per case per refresh instead of once per field.
- Per-case progress is estimated from the latest time directory relative to
  `startTime` and `endTime`.
- Duplicate parameter combinations are skipped before a case is registered.
- Worker copies use `cp --reflink=auto` when available.
- `constant/polyMesh` and `Mesh/*.msh` are not copied into worker directories,
  because the mesh is rebuilt from the `.geo` source.
- `finalize_database` uses `nullglob` instead of noisy glob expansion.
- `coreScreening` now accepts `true`, `1`, `yes`, or `on`.
- `allParametric` no longer calls `./Allclean` after a run, so
  `parametricStudy/` and `paramDatabase/` are preserved.

### Fixes

- `testCase/Allrun` reads `processors` from `system/paramDict` when `NP` is not
  exported, so standalone `./Allrun` runs with the requested core count.
- `core/cases.sh` uses `$PARAM_DICT` instead of a hard-coded path.
- `testCase/Allclean` no longer prints errors for missing globs.

## 2026-10-24 — Parallel case execution and console UI

### Summary

The parametric engine previously generated and ran every case sequentially.
`core/parallel.sh` existed but was not sourced or called.  This change wires the
parallel scheduler into the main controller, separates case generation from case
execution, fixes result archiving paths, and adds a consistent console UI.

### File-by-file changes

#### `allParametric`

- Resolves `CASE_DIR` to an absolute path before `cd`.
- Sources `core/ui.sh` and `core/parallel.sh`.
- Defines:

  ```bash
  PARAMETRIC_STUDY_DIR="$CASE_DIR/parametricStudy"
  PARAMETRIC_WORK_DIR="$CASE_DIR/parametricWork"
  PARAMETRIC_LOG_DIR="$CASE_DIR/parametricLogs"
  PARAMETRIC_STATUS_DIR="$CASE_DIR/parametricStatus"
  ```

- Calls `validate_core_budget` after loading `paramDict`.
- Calls `run_all_cases` after `generate_cases`.
- Removes the temporary `calculationScript.backup` after `./Allclean`.
- Uses `ui_banner`, `ui_section`, `ui_kv`, and `ui_ok` for console output.

#### `core/config.sh`

- Reads `availableCores` and `maxConcurrentCases` from `paramDict`.
- Defaults:

  ```bash
  availableCores=${availableCores:-$(nproc)}
  maxConcurrentCases=${maxConcurrentCases:-auto}
  ```

- Moves `paramNames` parsing before the configuration printout.
- Prints the configuration through `ui_kv`.

#### `core/cases.sh`

- `generate_cases` now only builds the case matrix.
- Removed all per-case `run_simulation` and `archive_case` calls from the
  generator.
- Added `register_case` to validate the parameter count and append to:

  ```bash
  CASE_NAMES
  CASE_VALUES
  ```

- Supports both user-defined `sets` and full Cartesian combinations.
- Uses `ui_info` and `ui_case` for output.

#### `core/parallel.sh`

- Clears stale work, log, and status directories before a run.
- Validates `availableCores`, `processors`, `coreList`, and
  `maxConcurrentCases`.
- Computes the maximum number of concurrent cases:

  ```bash
  maxParallel = min(totalCases, availableCores / processors)
  ```

- Respects an explicit `maxConcurrentCases`.
- Copies the base case into an isolated `parametricWork/<caseName>` directory.
- Removes stale `constant/polyMesh` before running.
- Replaces parameters in the worker `calculationScript`.
- Writes derived properties into the base `paramDatabase`.
- Runs `Allrun` with `NP=processors`.
- Copies timing metadata back to the base `parametricLogs`.
- Archives into the base `parametricStudy`.
- Removes the worker directory on success.
- Keeps the worker directory on failure.
- Copies failed worker logs into the archived case directory.
- Excludes `parametricStatus` from worker copies.
- Uses `ui_section`, `ui_kv`, `ui_info`, `ui_ok`, and `ui_error`.

#### `core/solver.sh`

- Captures the real `Allrun` exit code.
- Returns that code to the scheduler, so failed cases are recorded correctly.
- Prints success or failure through `ui_ok` / `ui_error`.

#### `core/archive.sh`

- Archives into `PARAMETRIC_STUDY_DIR` instead of the worker-local
  `parametricStudy` directory.
- Copies `runScript.py` only when it exists.
- Fixed the time-directory regex.  The old regex:

  ```bash
  ^[0-9]+([.eE+-][0-9]+)*$
  ```

  did not match scientific-notation directories such as `1e-4`.  The new regex:

  ```bash
  ^[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$
  ```

  matches `1e-4`, `1e+4`, `1.5e-3`, and `1.0e-05`.
- Uses `ui_info`, `ui_debug`, and `ui_warn`.

#### `core/database.sh`

- Removes the temporary `parametricStatus` directory after consolidation.
- Removes the redundant `rm -f parametricLogs/*_time.txt`.
- Uses `ui_info`, `ui_ok`, and `ui_debug`.

#### `core/utils.sh`

- Uses `ui_info`, `ui_debug`, `ui_error`, and `ui_kv`.
- Keeps append-index detection and core-count handling unchanged.

#### `core/coreScreening.sh`

- Uses `ui_section`, `ui_info`, `ui_kv`, and `ui_ok`.
- Formats the core-scaling table with aligned columns.

#### `core/mesh.sh`

- Returns a failure when the mesh source is missing.
- Uses `ui_error`.

#### `core/physics.sh`

- Returns a failure instead of exiting when a parameter is defined with
  `#calc`.
- Uses `ui_error`.

#### `core/ui.sh` — new

- Added colour-aware console helpers.
- Colours are enabled only for interactive terminals.
- `NO_COLOR=1` disables colours.
- `UI_WIDTH` controls the rule width.
- Added `ui_banner`, `ui_section`, `ui_info`, `ui_ok`, `ui_warn`,
  `ui_error`, `ui_kv`, `ui_case`, and `ui_debug`.

#### `testCase/Allrun`

- Propagates failures from mesh generation, decomposition, `mpirun`, and the
  serial solver.
- Skips `reconstructPar` when there are no non-zero processor time directories.
  This avoids a false failure with `reconstructPar`’s “No times selected” warning.
- Uses ASCII arrows in messages for log portability.

#### `testCase/system/paramDict`

- Removed the stray `parallelEnabled` entry.
- Added:

  ```foam
  availableCores      24;
  maxConcurrentCases  auto;
  ```

- Documented `processors` as “cores per case”.

#### `testCase/constant/fluid`

- Removed the stale unused mesh copy.  `Allrun` generates
  `constant/polyMesh`, which is what the solver reads.

### Case status dashboard

- Added `core/status.sh` with:
  - per-case status files in `parametricStatus/<caseName>.status`;
  - `QUEUED`, `RUNNING`, `DONE`, and `FAILED` states;
  - start, end, elapsed, and return-code tracking;
  - `fmt_duration` for elapsed-time formatting;
  - a plain-text dashboard written to `parametricStatus/dashboard.txt`.
- Updated `core/parallel.sh` to:
  - initialise every case as `QUEUED`;
  - mark a case `RUNNING` before its workspace is prepared;
  - mark it `DONE` or `FAILED` when the worker exits;
  - refresh the dashboard while jobs are running on a TTY;
  - print the final dashboard after the queue drains.
- The dashboard shows only elapsed time.  It does not display an ETA.
- The TTY refresh moves the cursor back over the previous table, clears each
  line, and rewrites it.  There is no full-screen clear, so the display does not
  flicker.
- Live refresh can be disabled with `STATUS_LIVE=0`.
- In-place redraw can be disabled with `STATUS_REDRAW=0`.
- Updated `core/database.sh` to preserve the final dashboard as
  `paramDatabase/status.txt` before removing `parametricStatus`.
- Updated `core/config.sh` to read:

  ```foam
  statusRefresh     1;
  ```

- Updated `allParametric` to source `core/status.sh`.
- Updated `testCase/system/paramDict` with the refresh entry.

### Verification

```bash
cd "$FOAM_SRC/solutionMonitoring/parametricStudy/allParametric"

for f in allParametric core/*.sh; do
    bash -n "$f" || echo "FAIL $f"
done

cd "$FOAM_SRC/solutionMonitoring"
git diff --check -- parametricStudy
```

A full run on a throwaway copy produced:

```text
Total cases       : 2
Cores per case    : 8
Available cores   : 24
Concurrent cases  : 2
Core budget used  : 16 / 24
```

Both cases completed, were archived, and were written to `paramTable.csv`.
Cartesian mode, append mode, and invalid core-budget rejection were also tested.

The status dashboard was tested with:

- queued cases at start-up;
- running cases with live elapsed time;
- completed cases with final elapsed time;
- failed cases with `FAILED` state;
- final snapshot preserved as `paramDatabase/status.txt`;
- smooth in-place TTY refresh and `STATUS_LIVE=0` / `STATUS_REDRAW=0` controls.

### Compatibility notes

- `availableCores` should be set for the target machine.
- `processors` must be less than or equal to `availableCores`.
- `maxConcurrentCases auto` is the recommended setting.
- The real solver must be available in `PATH` or in `FOAM_USER_APPBIN`.
