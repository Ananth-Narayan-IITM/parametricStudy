# OpenFOAM Parametric Study Engine

This directory contains the controller and supporting modules for running
OpenFOAM parametric studies, grid-independence studies, and core-scaling
studies.  The current version supports **multiple cases running at the same
time**, limited by the number of available cores and the number of cores
requested per case, plus **tagged study suites** that share one global queue and
can optionally merge their results into the main case folders.  Suite cases can
run locally or on multiple nodes through passwordless SSH.

## Contents

1. [Directory layout](#1-directory-layout)
2. [Quick start](#2-quick-start)
3. [`system/paramDict` reference](#3-systemparamdict-reference)
4. [Execution flow](#4-execution-flow)
5. [Parallel case scheduler](#5-parallel-case-scheduler)
6. [Tagged studies / suite mode](#6-tagged-studies--suite-mode)
7. [Output layout](#7-output-layout)
8. [Console UI module](#8-console-ui-module)
9. [Case status dashboard](#9-case-status-dashboard)
10. [Reproducing the changes](#10-reproducing-the-changes)
11. [Notes](#11-notes)

---

## 1. Directory layout

```text
parametricStudy/
├── allParametric                  # main entry point
├── copyToNodes                    # code/template sync for worker nodes
├── testMultiNode                  # multi-node execution verification
├── core/
│   ├── ui.sh                       # console formatting helpers
│   ├── config.sh                   # paramDict reader and identity
│   ├── utils.sh                    # modes, append index, backup cleanup
│   ├── mesh.sh                     # gmsh parameter replacement
│   ├── physics.sh                  # calculationScript replacement
│   ├── solver.sh                   # Allrun wrapper and timing
│   ├── archive.sh                  # result archiving
│   ├── database.sh                 # CSV consolidation
│   ├── matrix.sh                   # persistent caseMatrix.csv
│   ├── cases.sh                    # case-matrix generation
│   ├── rerun.sh                    # rerun selected cases
│   ├── caseInfo.sh                 # --case details and logs
│   ├── clean.sh                    # generated-data cleanup
│   ├── status.sh                   # status files and dashboard
│   ├── runDetails.sh               # timing, logging, summary
│   ├── parallel.sh                 # parallel case scheduler
│   ├── coreScreening.sh            # core-scaling study
│   ├── suite.sh                    # tagged study controller
│   └── distributed.sh              # node discovery, SSH workers, pulls
├── testCase/
│   ├── Allrun                      # entry point; sources the two below
│   ├── AllrunSimple                # all plain case commands
│   ├── Allclean
│   ├── calculationScript
│   ├── 0/
│   ├── constant/
│   ├── Mesh/
│   ├── system/
│   └── tags/                       # coarse/fine tagged examples
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

`testCase` includes a tagged example under `testCase/tags` (`coarse` and `fine`)
and has `tag true` in its main `system/paramDict`.  To run it as the
original single study instead, set:

```text
tag false;
```

`testCase/system/nodes.conf` starts with one local node, so the same case is
valid for a single machine.  To run the suite on several machines, add `ssh`
entries, set `distributed true` in the main `paramDict`, and synchronize the
code/templates with `./copyToNodes testCase`.  See
[Distributed execution](#distributed-execution).

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

## 6. Tagged studies / suite mode

A tagged study runs several independent case configurations under one controller.

```text
caseDir/
├── system/paramDict                 # tag / tagCases
├── tags/
│   ├── coarse/
│   │   ├── system/paramDict         # independent config, no tag
│   │   ├── Mesh/
│   │   ├── calculationScript
│   │   ├── parametricStudy/
│   │   └── paramDatabase/
│   ├── medium/
│   └── fine/
└── parametricSuite/
    ├── caseIndex.csv
    ├── cases.csv
    ├── summary.csv
    ├── sequence
    ├── queue.csv
    └── tags/*.status
```

Enable it in the main `system/paramDict`:

```text
tag   true;
tagCases (coarse medium fine);
tagMerge false;                 // true = collect all results into main folders
availableCores 32;              // global suite budget
maxConcurrentCases auto;        // optional global cap
```

When `tag=false` (default), the main directory behaves exactly as a
normal single study.

Each selected tag must contain its own complete `system/paramDict`. Tag
`paramDict` files must not contain `tag` or `tagCases`.

The suite scheduler:

- builds one global queue containing all cases from all selected tags;
- uses the same `processors` value for every tag;
- starts the next case as soon as a processor slot is free;
- runs cases in their own tag directory;
- keeps per-tag `parametricStudy`, `paramDatabase`, logs, work and status;
- prints the planned queue before starting;
- reports each launch and each completion with the tag, case, node,
  end time, elapsed time, running cases, and queued cases.

At the start of a suite run the case table shows the tag, case name, state and
parameter values.  The same table is printed again at the end, so the queue and
the final status are visible together.

During the run, each launch and completion is reported in the same style as a
single untagged study:

```text
[INFO] Launching coarse/c0R6v1 on localA  (M=10 T=30)
[ OK ] Completed coarse/c0R6v1 at 2026-11-28 19:50:37 on localA  (00:00:40)
  Running              fine/c0R6v3@localB, fine/c0R6v4@localA
  Queue                none
```

Failed cases use the same layout with the failure reason:

```text
[FAIL] Failed fine/c0R6v3 at 2026-11-28 19:52:11 on localB after 00:00:40
       (exit 1: command or solver reported failure; reason: ...)
  Running              coarse/c0R6v2@localA
  Queue                fine/c0R6v4
```

### End-to-end tagged workflow

1. Enable the suite in the main `system/paramDict`:

   ```text
   tag        true;
   tagCases   (coarse fine);
   tagMerge   false;
   ```

2. Create each tag directory with its own complete configuration:

   ```text
   tags/coarse/system/paramDict
   tags/coarse/calculationScript
   tags/coarse/Allrun
   tags/coarse/AllrunSimple
   tags/coarse/Mesh/
   ```

3. Run all tags through the shared scheduler:

   ```bash
   allParametric --delete
   ```

   Or limit the run to selected tags:

   ```bash
   allParametric --append --tag coarse
   allParametric --tags "coarse fine" --append
   ```

4. Inspect progress and the per-tag case list:

   ```bash
   allParametric --suite-status
   ```

5. Collect results in the main folders, if wanted:

   ```bash
   allParametric --merge-tags
   ```

   With `tagMerge true`, the same merge runs automatically after the suite
   finishes successfully.

6. Append another batch later:

   ```bash
   allParametric --append
   ```

   The suite index and summary keep both the merged cases and the new cases.

7. Inspect or rerun a case by name or `tag/case`:

   ```bash
   allParametric --case coarse/h0R20v4
   allParametric --rerun coarse/h0R20v4
   ```

8. Remove generated results when finished:

   ```bash
   allParametric --clean --yes
   ```

   This removes all tag results, the merged main results, and
   `parametricSuite/` once no cases remain.  Tag configuration, `Mesh/`,
   scripts, and `system/` are kept.  Use `--tag <name>` to clean only one tag.

### Case numbering

The next case is always:

```text
highest existing number across all tags and merged main cases + 1
```

Deleting the highest case makes that number available again. Deleting an
intermediate case leaves the next number unchanged. `--reset-sequence` is the
explicit form of this default behaviour.

### Suite commands

```bash
allParametric --append --tag coarse
allParametric --delete-cases h0R20v4 h0R20v7
allParametric --delete-cases h0R20v4 h0R20v7 --dry-run
allParametric --reset-sequence
allParametric --case coarse/h0R20v4
allParametric --rerun coarse/h0R20v4
allParametric --suite-status
allParametric --merge-tags
```

`--delete-cases` removes the selected archives, matrix rows and table rows; it
rebuilds each affected tag’s `paramTable.csv` and updates the suite index and
summary. A suite lock prevents concurrent append/delete operations.

`parametricSuite` is coordination/reporting only:

| File | Purpose |
|---|---|
| `caseIndex.csv` | Maps tag, case name, and global case number |
| `cases.csv` | Per-case tag, case name, number, status, node, and failure reason |
| `summary.csv` | Per-tag counts, state, first/last case, and full case list |
| `queue.csv` | Queue for the current suite run |
| `sequence` | Latest highest and next case number |
| `tags/<tag>.status` | Per-tag progress and counts |
| `logs/` | Case-generation and tag-finalization logs |
| `suite.lock` | Prevents concurrent suite operations |

The suite summary is printed as a table:

```text
Tag          Cases  Done   Failed  Status     Cases
coarse       3      3      0       DONE       c0R6v1 c0R6v2 c0R6v3
fine         3      3      0       DONE       c0R6v4 c0R6v5 c0R6v6
```

Per-case results stay in each tag’s own `paramDatabase` unless
`tagMerge true` is set.  In that case the suite copies archives and merges the
matrix/table into the main `parametricStudy/` and `paramDatabase/`, adds the
`tag` column, and removes the tag result folders after a successful merge.
The merge can also be run explicitly with `--merge-tags`.

Merging is incremental.  Running `--append` later and merging again keeps the
existing main cases and adds the new ones.  If a case was rerun in a tag, its
new archive and table row replace the older main row.  Rerunning or inspecting a
merged case works from the main result tree when the tag result has already been
removed.

Appending also updates `parametricSuite/caseIndex.csv`, `cases.csv`, and
`summary.csv` with both the already-merged cases and the new cases.  The
`parametricSuite/` folder is kept after a merge so `--suite-status` can report
the complete suite; whole-suite cleanup removes it once there are no cases left.
Empty generated folders such as an empty `parametricLogs/` are removed after a
merge.

### Distributed execution

The same tagged suite can run on several machines.  Distributed mode is
disabled by default.

Main `system/paramDict`:

```text
distributed true;
nodesFile   system/nodes.conf;
```

`system/nodes.conf`:

```text
# name transport rank cores tempRoot
local local 0 auto auto
node1 ssh 1 auto auto
node2 ssh 2 auto auto
node3 ssh 3 auto auto
```

Fields:

| Field | Meaning |
|---|---|
| `name` | Display name, and SSH alias when `transport=ssh` |
| `transport` | `local` or `ssh` |
| `rank` | Scheduling tie-breaker; lower number is preferred |
| `cores` | `auto` (use `nproc`) or a positive integer |
| `tempRoot` | `auto` (`$HOME/.parametricStudy`) or an absolute path |

Requirements:

- Passwordless, non-interactive SSH must work for every `transport=ssh` node.
- `ssh` and `rsync` must be available on the master.
- Each worker needs a writable `tempRoot`.
- All nodes must be able to run the same `processors` ranks per case.

#### Passwordless SSH setup

The engine uses:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 <node> ...
```

`BatchMode=yes` disables password and passphrase prompts.  The SSH key must
therefore be usable without interaction, or loaded in `ssh-agent`.

Inside the container, create a key if needed:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

Add an SSH alias.  The node name in `nodes.conf` must match the `Host` name:

```text
Host taylor
    HostName 10.21.153.233
    User taylor
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
```

Install the public key on the worker account:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub taylor
```

If `ssh-copy-id` cannot connect yet, append the contents of
`~/.ssh/id_ed25519.pub` to the worker’s `~/.ssh/authorized_keys` manually.

Check permissions:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/id_ed25519 ~/.ssh/authorized_keys
chmod 644 ~/.ssh/id_ed25519.pub
```

Test exactly what the engine needs:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 taylor \
    'hostname; id -un; nproc; command -v rsync; command -v setsid'

rsync -a testCase/system/nodes.conf taylor:/tmp/nodes-test.conf
```

Both commands must work without a password or passphrase prompt.

#### Docker networking

Inside a Docker container, `taylor` may not resolve because the container has
its own `/etc/hosts`.  Use the host LAN IP in `~/.ssh/config`:

```text
Host taylor
    HostName 10.21.153.233
```

If the host is reachable only through the Docker gateway, start the container
with:

```bash
--add-host=host.docker.internal:host-gateway
```

and use:

```text
Host taylor
    HostName host.docker.internal
```

Ensure the worker’s SSH server is listening on the container-visible interface
and that the firewall allows the connection.  If the machine has only one
compute node, use:

```text
local local 0 auto auto
```

and remove the `taylor ssh ...` entry.  `local` means the container itself;
`taylor ssh` means connecting back to the host over SSH.

Once SSH works, validate the full path with:

```bash
./testMultiNode --nodes-file testCase/system/nodes.conf
```

Scheduling:

- The master keeps the authoritative queue and global case numbers.
- Each node has `floor(cores / processors)` slots.
- The scheduler prefers the node with the fewest active cases, so every node
  with a free slot is used.  Node rank breaks ties, with rank 0 first.
- `maxConcurrentCases auto` uses all node slots.  An explicit value caps the
  total number of running cases.
- `availableCores` is the local-mode budget; distributed capacity comes from
  each node’s `cores`/`nproc`.

Synchronize code and tag templates before a distributed run:

```bash
./copyToNodes /path/to/case
```

`copyToNodes` supports the same `system/nodes.conf` used by the distributed
engine:

- with `ssh` entries, it copies `allParametric`, `core/`, and tag templates to
  each worker’s `tempRoot`;
- with no nodes file, or a nodes file containing only local entries, it falls
  back to the built-in legacy node list and copies the engine tree to
  `$HOME/AM24D038/DAFoam/parametricStudy` on each listed node.

It also accepts the legacy node format:

```text
user host [port] [remote_dir]
```

Use `--nodes-file <file>` to choose a specific list, `--dry-run` to preview, and
`--yes` for non-interactive operation.  Result folders, work/log/status folders,
backup folders, processor folders, and `.git` are excluded.

Distributed case lifecycle:

1. The master creates a job and copies the reusable tag base into an isolated
   job directory on the worker.
2. The worker runs the case detached with `setsid`/`nohup`.
3. On success, the worker writes `PULL_COMPLETE` only after the archive,
   status, logs, and metadata are complete.
4. The master pulls the result into a staging directory and verifies the suite
   ID, job ID, tag, case, and archive before moving it into place.
5. Only then is the central status updated to `DONE`.
6. A failed worker writes a `FAILED` marker with the reason and exit code.
   The master marks the case failed and does **not** pull a partial archive.
7. Failed cases are never retried automatically.  Failed remote work
   directories are kept for debugging.
8. If a node becomes unreachable, its running cases are marked failed and the
   remaining nodes continue with the global queue.

Successful remote job directories are removed after the pull.  The reusable
tag base remains on the worker for the next case.  `--clean` removes local
results and also cleans remote job/base folders for the selected scope.

Verify the complete distributed path, including SSH launch, detached workers,
result pull, and node metadata, with a throwaway copy of `testCase`:

```bash
./testMultiNode --nodes-file /path/to/nodes.conf
```

The test uses a lightweight `AllrunSimple` that records the executing node and
does not run the solver.  It checks that every case completed, every
`PULL_COMPLETE` marker exists, the merged table and archives contain the node
metadata, and multiple configured nodes were used when enough cases exist.
Use `--keep` to keep the temporary test directory.

Each case runs on one worker node.  This verifies master-to-worker communication
and result transfer; it does not run a single MPI job across multiple nodes.

Distributed metadata stored per case:

| Column | Meaning |
|---|---|
| `nodeAlias` | Scheduler node name |
| `transport` | `local` or `ssh` |
| `suiteId` | Suite run identifier |
| `jobId` | Per-case job identifier |
| `node` | Execution identity (`user@ip`) |
| `user`, `ip` | Execution user and machine IP |

The suite case table and `parametricSuite/cases.csv` show the assigned node:

```text
Tag          Case           State        Node           Parameters
coarse       c0R6v1         DONE         localA         M=10 T=30
fine         c0R6v3         RUNNING      localB         M=10 T=30
```

## 7. Output layout

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
caseName, tag, studyType, runTag, runComment, authorNote,
node, nodeAlias, user, ip, sshIp, identitySource,
transport, suiteId, jobId,
startTime, endTime, elapsedTime (s), status, reason, exitCode,
<paramDict parameters>,
<resolved calculationScript values excluding paramDict parameters>
```

In tagged mode, the `tag` column records the source tag in every per-tag table.
After a merge, the same column in the main table keeps the tag for filtering.

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
| `nodeAlias` | Scheduler node name from `system/nodes.conf` |
| `transport` | `local` or `ssh` |
| `suiteId` | Suite run identifier |
| `jobId` | Per-case job identifier |
| `user` | user that ran the case |
| `ip` | IP of the machine that actually executed the case |
| `sshIp` | IP of the machine the user connected from; empty for a local run |
| `identitySource` | `local`, `host-env`, or `container` |

`identitySource` is the source category, while `nodeAlias` is the scheduler
node name.  Pass `PARAMETRIC_HOST_NODE` to set the execution node name
explicitly.  `sshIp` is the connection origin, while `node` is the machine that
actually executed the case.  Only the IP is recorded; no username or reverse lookup is
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

# Scheduler metadata normally set by the suite controller
export PARAMETRIC_NODE_ALIAS=...
export PARAMETRIC_TRANSPORT=local # local | ssh
export PARAMETRIC_SUITE_ID=...
export PARAMETRIC_JOB_ID=...
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

The scheduler `Node` column and the `nodeAlias` metadata prefer
`PARAMETRIC_HOST_NODE`, then the host user when running inside a container, and
only fall back to `hostname` when no host identity is available.  This prevents
the random Docker container ID from appearing as the node name.

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
allParametric --append --tag <tag> # limit a tagged run to one tag
allParametric --append --tags "coarse fine"  # limit to several tags
allParametric --delete-cases <case...>  # or -D; remove selected cases
allParametric --delete-cases <case...> --dry-run
allParametric --reset-sequence  # or -R; default highest+1 behaviour
allParametric --suite-status    # tag status, suite summary, and cases
allParametric --merge-tags      # collect tag results into the main folders
allParametric --clean           # or -x; asks before deleting generated results
allParametric --clean --yes     # non-interactive whole-suite cleanup
allParametric --tag <tag> --clean --yes  # clean one tag and its merged cases
allParametric --save-on-failure  # or -s; write partial results automatically
allParametric --export       # add this directory to PATH

./copyToNodes [caseDir]      # sync engine/templates to nodes.conf or legacy list
./testMultiNode --nodes-file <file>  # verify multi-node execution
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

In tagged mode, `--clean` asks for a cleanup scope:

```text
1) whole suite: remove all tag results and merged main results
2) individual tag: clean each selected tag and its merged main cases
```

Whole-suite cleanup removes `parametricStudy/`, `paramDatabase/`,
`parametricWork/`, `parametricLogs/`, `parametricStatus/`, and
`coreScalingLogs/` for every selected tag and for the merged main result tree.
It also removes `parametricSuite/` once no cases remain. Tag `system/`, `Mesh/`,
scripts, and other configuration files are kept.

`--clean --yes` uses whole-suite cleanup non-interactively. With `--tag` or
`--tags`, only the selected tags and their merged main cases are removed; other
tags remain and `parametricSuite/` is kept.

`--suite-status` needs `parametricSuite/` while results exist. It is recreated
automatically by the next suite run after cleanup.

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

## 8. Console UI module

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

## 9. Case status dashboard

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
reason=<failure reason>
node=<scheduler node>
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

## 10. Reproducing the changes

### 10.1 Restore a clean test case

```bash
cd "$FOAM_SRC/solutionMonitoring/parametricStudy/testCase"

rm -rf constant/fluid \
       parametricStudy paramDatabase \
       parametricLogs parametricStatus parametricWork \
       coreScalingLogs parametricSuite \
       \[backup*\]* \
       c0R6v*.txt calculationScript.backup

rm -rf tags/*/parametricStudy tags/*/paramDatabase \
       tags/*/parametricLogs tags/*/parametricStatus \
       tags/*/parametricWork tags/*/coreScalingLogs \
       tags/*/\[backup*\]*

git checkout -- 0/alphat 0/p Mesh/c0R6_OF.msh
```

### 10.2 Verify syntax

```bash
cd "$FOAM_SRC/solutionMonitoring/parametricStudy"

for f in allParametric copyToNodes testMultiNode core/*.sh \
         testCase/Allrun testCase/AllrunSimple \
         testCase/tags/*/Allrun testCase/tags/*/AllrunSimple; do
    bash -n "$f" || echo "FAIL $f"
done

cd "$FOAM_SRC/solutionMonitoring"
git diff --check -- parametricStudy
```

### 10.3 Tagged suite smoke test

`testCase` has `tag true`, so it runs the `coarse` and `fine` examples:

```bash
rm -rf /tmp/opencode/testCase-run
cp -a "$FOAM_SRC/solutionMonitoring/parametricStudy/testCase" /tmp/opencode/testCase-run

cd "$FOAM_SRC/solutionMonitoring/parametricStudy"
./allParametric /tmp/opencode/testCase-run --delete
```

Check the per-tag databases and suite summary:

```bash
cat /tmp/opencode/testCase-run/parametricSuite/summary.csv
cat /tmp/opencode/testCase-run/parametricSuite/cases.csv
cat /tmp/opencode/testCase-run/tags/coarse/paramDatabase/paramTable.csv
cat /tmp/opencode/testCase-run/tags/fine/paramDatabase/paramTable.csv
```

Test the merge, status, and cleanup paths:

```bash
./allParametric /tmp/opencode/testCase-run --merge-tags
cat /tmp/opencode/testCase-run/paramDatabase/paramTable.csv
./allParametric /tmp/opencode/testCase-run --suite-status
./allParametric /tmp/opencode/testCase-run --clean --yes
```

After cleanup, the tag configuration remains, while the generated result
folders and `parametricSuite/` are removed.

### 10.4 Single-study smoke test

Use one tag directory as a normal, non-tagged case:

```bash
rm -rf /tmp/opencode/single-run
cp -a "$FOAM_SRC/solutionMonitoring/parametricStudy/testCase/tags/coarse" \
      /tmp/opencode/single-run

cd "$FOAM_SRC/solutionMonitoring/parametricStudy"
./allParametric /tmp/opencode/single-run --delete
cat /tmp/opencode/single-run/paramDatabase/paramTable.csv
```

This database has the same columns, with every row tagged `untagged`.

### 10.5 Distributed local smoke test

This tests the node scheduler without needing SSH.  Use two local nodes with one
slot each:

```bash
cp -a "$FOAM_SRC/solutionMonitoring/parametricStudy/testCase" \
      /tmp/opencode/distributed-run

cat > /tmp/opencode/distributed-run/system/nodes.conf <<'EOF'
localA local 0 1 auto
localB local 1 1 auto
EOF

# Set distributed true and tagMerge true in system/paramDict, and use
# processors 1 in the main and tag paramDict files.

cd "$FOAM_SRC/solutionMonitoring/parametricStudy"
./allParametric /tmp/opencode/distributed-run --delete
cat /tmp/opencode/distributed-run/parametricSuite/cases.csv
cat /tmp/opencode/distributed-run/paramDatabase/paramTable.csv
```

Expect the cases to alternate between `localA` and `localB` in the `Node`
column.  For a real cluster test, replace the local entries with passwordless
SSH aliases:

```text
master local 0 auto auto
node1 ssh 1 auto auto
node2 ssh 2 auto auto
node3 ssh 3 auto auto
```

Then run:

```bash
./copyToNodes /tmp/opencode/distributed-run
./allParametric /tmp/opencode/distributed-run --delete
```

---

## 11. Notes

- Local scheduling uses `availableCores` as the core budget.  Distributed
  scheduling uses the per-node `cores`/`nproc` values in `system/nodes.conf`
  and `maxConcurrentCases` as the global cap.
- Distributed nodes are filled by rank priority.  The master is normally rank 0;
  lower rank numbers are used first.
- Distributed mode requires passwordless SSH and `rsync`.  The reusable tag
  bases and detached workers are described under
  [Distributed execution](#distributed-execution).
- `availableCores` is machine-specific.  Set it to the number of local cores you
  want the local scheduler to use, not necessarily `nproc`.
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
- `--delete` now asks whether to delete those `[backup*]` result folders too.
  The default answer is `Y`.
- `--append` continues the case numbering from the highest existing
  `<prefix><number>` directory, including cases already merged into the main
  result tree.
- `reconstructPar` is skipped when the solver has not written any non-zero time
  directory, avoiding a false “No times selected” failure.
- Scientific-notation time directories such as `1e-4` are archived correctly.
- Tag `paramDict` files must not contain `tag` or `tagCases`, and all selected
  tags must use the same `prefix` and `processors`.
- `tagMerge` is incremental.  It replaces a main row only when the same case was
  rerun in its tag; otherwise it appends new cases.
- A merge never deletes tag results if a tag still has unfinished or failed
  cases.  The failed work directory is kept for debugging.
- `--case`, `--rerun`, and `--delete-cases` resolve cases from the main result
  tree after a merge, so the tag result folders do not need to be kept.
- `--clean --yes` removes merged main results and all tag results.  Add
  `--tag <name>` to clean only one tag and its main rows.
- `--suite-status` reads `parametricSuite/`; that folder is removed by cleanup
  only when no cases remain and is recreated by the next suite run.
