# Changelog

## 2026-11-28 — Distributed tagged-suite execution

- Added optional distributed execution controlled by `distributed` and
  `nodesFile` in the main `system/paramDict`.
- Added `system/nodes.conf` with one entry per node:
  `name transport rank cores tempRoot`.
- Added automatic `nproc` discovery and per-node slot calculation.
- Added balanced scheduling across all configured nodes, with node rank as the
  tie-breaker, while preserving the global tag queue and global case numbering.
- Added passwordless SSH preflight, detached `setsid`/`nohup` workers, reusable
  per-tag base directories, and isolated per-case job directories.
- Added `PULL_COMPLETE`: the master pulls a result only after the worker has
  written the archive, status, logs, and metadata.  Pulls use a staging
  directory and atomic move; partial archives are never accepted.
- Added failure markers and no automatic retry.  Node loss marks affected cases
  failed while remaining nodes continue.
- Added `nodeAlias`, `transport`, `suiteId`, and `jobId` metadata to
  `paramTable.csv`; `cases.csv` now records node and failure reason.
- Suite output now shows `Tag`, case, state, node, and parameters.
- Suite progress now follows the untagged display: `Launching ...`, and on
  completion `Completed/Failed ... at <time> on <node>`, followed by the
  currently running and queued `tag/case@node` lists.
- Node labels now prefer the host identity (`PARAMETRIC_HOST_NODE`, then host
  user in a container) instead of the random Docker container hostname.
- Suite case and summary tables now auto-size their columns to the terminal
  width, preventing long tag names from colliding with adjacent columns.
- Added remote job/base cleanup for whole-suite and filtered cleanup.
- Added `copyToNodes` synchronization of engine code and tag templates using the
  same `system/nodes.conf`.
- Restored the legacy `copyToNodes` workflow: `user host [port] [remote_dir]`
  entries and the built-in node list are supported again.  A missing nodes file,
  or a nodes file with only local entries, falls back to that legacy list so the
  engine can be synchronized to the existing worker nodes.
- Added `testMultiNode`, a throwaway-case verification that runs the distributed
  suite, checks `PULL_COMPLETE` markers, validates node metadata in the merged
  table and archives, and confirms that multiple configured nodes were used.
- Updated `allParametric --help` and README with node configuration, scheduling,
  synchronization, pull, failure, and metadata behavior.

## 2026-11-28 — Documentation pass

- Reworked `allParametric --help` into run, case, tagged-suite, and cleanup
  groups, with explicit tagged examples.
- Expanded the README with an end-to-end tagged workflow, suite file reference,
  merged/append/cleanup behavior, updated module and output layout, and revised
  tagged and single-study smoke tests.
- Documented the `tag` column, `tagMerge`, `--merge-tags`, `--suite-status`,
  whole-suite cleanup, filtered cleanup, and merged-case `--case`/`--rerun`
  behavior.
- Documented that `parametricSuite/` is kept for status reporting and removed
  when cleanup leaves no cases.

## 2026-11-28 — Tagged study suite

- Added tagged studies controlled by `tag` and `tagCases` in the main
  `system/paramDict` (replacing the earlier `tagedStudy`/`tagedStudies` names).
- Added a suite case table showing tag, case name, state, and parameter values.
  The table is printed before the run and again at the end, with live
  `RUNNING`/`DONE`/`FAILED` transition lines while cases run.
- Added `caseList` to the suite summary and `parametricSuite/cases.csv`.
- The suite summary now prints per-tag counts, state, and the list of cases that
  belong to each tag.
- Added a `tag` column to `paramTable.csv` and `caseMatrix.csv` in merged main
  databases; per-tag tables also record their tag.
- Added optional `tagMerge`: collect all tag results into the main
  `parametricStudy/` and `paramDatabase/` and delete tag result folders after a
  successful merge.
- Added `--merge-tags` for an explicit incremental merge. Existing main cases
  are kept, new cases are added, and rerun cases replace their older main rows.
- `--case`, `--rerun`, and `--delete-cases` work for cases already merged into
  the main result tree.
- Added a configuration `Tag` line in normal and tagged runs.
- `--clean` in tagged mode asks for whole-suite or individual-tag cleanup.
  Whole-suite cleanup removes generated result folders for all selected tags,
  removes the merged main result tree, and deletes `parametricSuite/` once no
  cases remain. Filtered cleanup removes only the selected tags and their merged
  main cases.
- Appending after a merge updates the suite index/summary with both merged and
  new cases.
- Empty generated folders left by a merge, such as an empty `parametricLogs/`,
  are removed.
- Each selected tag keeps independent `parametricStudy`, `paramDatabase`,
  logs, work and status directories.
- Added one global case queue across tags, with a shared processor budget and
  round-robin tag scheduling.
- Case numbering is global: next case = highest existing case across all tags
  and merged main cases, plus one. `--reset-sequence` is the explicit form of
  this default.
- Added `--delete-cases` for arbitrary case removal, including per-tag database
  and table rebuilds.
- Added `--tag`, `--tags`, `--suite-status`, and a suite lock under
  `parametricSuite/suite.lock`.
- Updated `allParametric --help` with the new commands.
- Added tagged examples under `testCase/tags`.
- `-d` now asks whether to delete `[backup*]` result folders; default is yes.

## 2026-11-28 — Failure reporting and optional partial database

- Added `status`, `reason`, and `exitCode` columns to `paramTable.csv`, so a
  failed case is visible in the database, not only in the console/status files.
- Failure reasons are more descriptive (`simulation failed with exit code 1`,
  `step "Case run" failed with exit code 1`, etc.).
- Added a failure footnote with human-readable descriptions for common exit
  codes: 1, 130, 137, 143, and others.
- On failure, the run now asks whether to write partial results to
  `paramDatabase` and clean temporary work/log/status directories.  The default
  answer is `N`.
- Added `--save-on-failure` / `-s` for non-interactive jobs, which writes the
  partial database automatically and removes the temporary work directories.
- If the answer is `N`, `parametricWork` is kept for debugging.

## 2026-11-23 — Record SSH origin IP only

- `paramTable.csv` now records only `sshIp` for the connection origin.  The
  origin username (`sshUser`) and reverse-resolved host (`sshHost`) columns were
  removed.
- `SSH from` in the console, `status.txt`, run logs, and `--case` shows the IP
  only.
- `PARAMETRIC_SSH_USER` and `PARAMETRIC_SSH_HOST` are no longer used.
  `SSH_CONNECTION` / `SSH_CLIENT` still provide `sshIp`, and
  `PARAMETRIC_SSH_IP` can override it.
- Legacy tables containing `sshHost`/`sshUser` remain readable; those extra
  columns are ignored.

## 2026-11-23 — Docker identity via environment only

- Removed `core/nodeMap.csv` and the container-to-host table lookup.  A table
  keyed by the container user cannot distinguish hosts when every container
  runs as the same user.
- Host identity is now passed explicitly from the host wrapper:
  - `PARAMETRIC_HOST_USER`
  - `PARAMETRIC_HOST_IP`
  - `PARAMETRIC_HOST_NODE` (optional node label; `PARAMETRIC_NODE` is an alias)
- `identitySource` is `host-env` when the host values are passed, `local`
  outside a container, and `container` otherwise.
- Added `sshUser`, `sshHost`, and `sshIp` so the SSH origin is recorded by
  username, host name, and IP:
  - `sshIp` comes from `SSH_CONNECTION`/`SSH_CLIENT`;
  - `sshHost` is reverse-resolved from `sshIp`, or set with
    `PARAMETRIC_SSH_HOST`;
  - `sshUser` is set with `PARAMETRIC_SSH_USER`, because SSH does not transmit
    the client's local username.
  Pass `SSH_CONNECTION`/`SSH_CLIENT` into Docker to keep the origin visible
  inside the container.
- If host identity is not passed in a container, the run warns and records the
  container identity.

## 2026-11-22 — Docker host identity mapping

- Detect when `allParametric` runs inside a container.
- Host identity can be passed from the host wrapper with
  `PARAMETRIC_HOST_USER` and `PARAMETRIC_HOST_IP`; these take precedence over
  the container identity.
- Added `core/nodeMap.csv` to map a container identity to a host identity.
  Matching keys are `containerUser`, `containerIp`, `hostname`, and
  `workspaceUid`.
- Added `identitySource` to `paramTable.csv` and archived case metadata:
  `local`, `host-env`, `host-map`, or `container`.
- Inside a container with no host mapping, the run warns and records the
  container identity instead of silently claiming it is the host.
- Duplicate keys in `core/nodeMap.csv` are reported; only the first matching row
  can ever be selected.
- The console label is now `Identity source`, making clear that values such as
  `host-map` describe where the identity came from, not the node name.
- Identity remains per case, so appending or rerunning does not rewrite earlier
  rows.

## 2026-11-22 — Automatic execution identity

- `node` is no longer read from `paramDict`.  The run now derives the execution
  identity automatically:
  - `user` — user that ran the case;
  - `ip` — IP of the machine that executed the case;
  - `sshIp` — IP of the machine the user connected from, empty for a local run;
  - `node` — `user@ip`.
- `paramTable.csv` now has `node,user,ip,sshIp` columns.
- The run aborts with a clear error if the user or execution IP cannot be
  determined.  `PARAMETRIC_USER`, `PARAMETRIC_NODE_IP`, `PARAMETRIC_SSH_IP`, and
  `PARAMETRIC_NODE` can override the detection.
- Identity values are written into each case workspace, archived with the case,
  and preserved per case when appending.
- The identity is shown in the configuration summary, `status.txt`, the run log
  header, and `allParametric --case`.
- Older tables remain readable; unknown identity fields stay blank instead of
  being guessed.

## 2026-11-22 — Execution node tracking

- Added an optional `node` entry to `paramDict`.  It labels the machine or
  cluster that ran a case and defaults to the local host name.
- The node is written into each case workspace before the run, archived with
  the case, and shown in `paramTable.csv` as the `node` column.
- `node` is preserved per case, like `runTag` and `runComment`, so appending on
  another machine does not rewrite earlier rows.
- Added the node to the configuration and status summary, the run log header,
  and `allParametric --case`.
- Legacy result tables without a `node` column remain readable; their node
  stays blank instead of being guessed.

## 2026-11-22 — Status history

- `paramDatabase/status.txt` is now appended instead of overwritten.  Each run
  adds its status board after a separator with the append timestamp, so earlier
  runs remain available.
- `allParametric --case` now reads the latest snapshot for a case, which matters
  when the same case appears in several appended runs (for example after a
  rerun).

## 2026-11-20 — Per-case run metadata

- Fixed `paramTable.csv` losing earlier run metadata on `--append`.  Rows are
  now built from each case's archived `system/paramDict`, so `runTag`,
  `runComment`, and `authorNote` keep the values used when that case ran.
  Older rows are no longer overwritten with the current configuration.
- Fallback order for metadata: archived case `paramDict`, previous table row,
  current `paramDict`.  This repairs tables that were already overwritten.
- Allows multiple append batches with different comments in one case
  directory, for example three sets of ten cases with different `runComment`.

## 2026-11-17 — Case matrix and rerun

- Added `allParametric --clean` / `-x` to remove generated parametric data.
  It asks for confirmation before deleting `parametricStudy` and
  `paramDatabase`; `--yes` skips the prompts.
- Added `allParametric --help` and short aliases `-d`, `-a`, `-b`, `-r`, `-c`, `-x`.
- Added `allParametric --case <caseName>` / `-c` to inspect a running or finished
  case: state, times, matrix values, resolved calculationScript values, log
  paths, and the last log lines.  Running cases follow the log live with
  `tail -F` and can be stopped with `Ctrl-C`.
- `-c` now asks `Show log? [Y/n]` (default yes).  Case values and details are
  printed after the log ends or is interrupted.
- Added `allParametric --export` to add the real `parametricStudy` directory to
  `~/.bashrc` (or `~/.zshrc`).
- Added `paramDatabase/caseMatrix.csv` as the authoritative source of submitted
  parameter values.
- Refactored `paramTable.csv` to contain:
  - case metadata and timing;
  - `paramDict` parameter values;
  - resolved `calculationScript` values from `foamDictionary calculationScript`,
    excluding `paramDict` parameters.
- Removed transport-property `.txt` dumps from `paramDatabase`.
- Added:
  ```bash
  allParametric rerun <case1> <case2> ...
  ```
  Rerun reads values from `caseMatrix.csv`, starts from the base case, replaces
  the selected archives, and updates the result table.
- `--append` synchronizes `caseMatrix.csv` with the directories present in
  `parametricStudy/`, then appends new cases.  Deleting a case directory allows
  that case name to be reused.
- Added script start time to the execution plan and final summary.
- Removed the `foamDictionary constant/transportProperties` call from each case,
  avoiding unnecessary code-stream compilation in the controller.

## 2026-10-25 — Elapsed-time-only status

- Removed live percentage, progress bars, and ETA from the case status table.
- Removed the per-second live refresh loop and `statusRefresh` setting.
- The status table is printed once at the end of the study.
- The status snapshot is written once at the end of the study.
- `dashboard.txt` and `paramDatabase/status.txt` are written without ANSI
  colour codes, so they are readable in a plain text editor.
- `status.txt` starts with a `paramDict` settings summary, including
  `continueFromPrevious`, solver, study type, prefix, parameters, cores,
  execution mode, and the log time zone.
- Human-readable timestamps default to `Asia/Kolkata` (IST).  The zone is set by
  `logTimeZone` in `paramDict` (or `LOG_TIMEZONE` in the environment).
- Full command output is now written outside the case directory during a
  parametric run, so case `Allclean` scripts cannot delete it.  It is archived
  as `log.Allrun.full`.
- `allParametric` can be invoked from inside a case directory:
  `allParametric --delete`.  It resolves symlinks so a case-local symlink also
  works.
- Per-case elapsed time is shown only after the case finishes.
- Added completion updates with wall-clock end time, currently running cases,
  and queued cases.  The same lines are saved to `parametricLogs/run.log`
  and `paramDatabase/run.log`.
- The final batch of running cases is now monitored with `wait -n`, so each
  completion is reported as it happens instead of only after the last job ends.
- Added a `Finished` wall-clock column to the final status table.  It shows the
  full date/time on wide terminals and `HH:MM:SS` on narrow terminals.
- Failed cases now record the failing step in the status file, for example
  `reason=reconstruct (rc=1)`, and show it in the status table and summary.
- The final summary keeps wall time, aggregate case time, core-utilization
  percentage, and fastest/slowest cases.  It has no progress percentage or ETA.

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

### Chained/hysteresis cases

- Added `continueFromPrevious` to `system/paramDict` (default `false`).
- When true:
  - duplicate detection is disabled, so hysteresis paths can revisit values;
  - execution is forced to one case at a time;
  - each case starts from the previous archived case;
  - the previous latest time directory becomes the new `0`, with `uniform`
    removed;
  - the mesh is kept from the previous case;
  - a failed case stops the chain and marks the remaining cases `SKIPPED`.
- Added `SKIPPED` state handling to the status dashboard and final summary.
- Added `ui_break_status_line` so `[INFO]`/`[OK]`/`[WARN]`/`[FAIL]` messages
  start on a new line after the live status line.
- `render_status_line` now writes `parametricStatus/dashboard.txt` on every
  refresh, so the live dashboard is available during a run.
- Chained cases now run in the background one at a time, so the live status line
  and dashboard continue updating during each chained simulation.
- `archive_case` now copies all run scripts (`Allrun`, `AllrunSimple`, `Allclean`,
  `preProcessing`, `updateRunScript`, `postProcess`, `runScript*.py`) and
  `0.orig`, so an archived case can seed the next chained case.
- Chained workspace preparation copies any missing run scripts from the base case
  when using an older archive.
- Chained workspace preparation replaces `0.orig` with the seeded `0`.  This
  lets the normal `preProcessing`/`Allclean`/`restore0Dir` sequence run without
  wiping the previous solution.  Removing `0.orig` alone is not sufficient because
  `Allclean` removes `0` first.

### Case-run structure

- `Allrun` now sources `AllrunSimple` and `core/runDetails.sh`, then calls
  `run_detailed_case`.
- `AllrunSimple` contains one clearly marked `OPENFOAM COMMANDS` block with all
  plain mesh/decompose/solve/reconstruct commands and can be run directly to check
  a case before a parametric study.
- `core/runDetails.sh` contains all timing, log diversion, progress, and summary
  code.
- `allParametric` exports `PARAMETRIC_CORE_DIR` so `Allrun` can find
  `core/runDetails.sh` both in the base case and inside worker directories.
- The case commands are no longer duplicated between the checking path and the
  parametric-study path.

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
