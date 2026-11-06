# SmartSbatch

**SmartSbatch** automatically estimates and optimizes memory and run-time for Slurm jobs to increase resource efficiency and decrease the amount of time jobs spend in pending status. It is pure Bash — no daemon, no database, no special runtime. Setup is to clone the repo and put it on your `PATH`.

Its tool, **`ssbatch`**, is a drop-in `sbatch` wrapper that estimates memory/time from your past jobs, picks a partition, resubmits on OOM/OOT, and sends informative emails.

> [!NOTE]
> Because it is plain Bash, installation is just `git clone`, and it slots into existing command-line tools and pipelines (Snakemake, Nextflow, Cromwell) without rewriting them.

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [ssbatch: smart sbatch](#ssbatch-smart-sbatch)
  - [Usage](#usage)
  - [Quick example](#quick-example)
  - [Utilities: unExport](#utilities-unexport)
  - [checkRun: monitor and debug](#checkrun-monitor-and-debug)
  - [cancelAllJobs](#cancelalljobs)
  - [How ssbatch works](#how-ssbatch-works)
    - [jobRecords.txt](#jobrecordtxt)
    - [config.txt](#configtxt)
    - [Resource estimation](#resource-estimation)
    - [Partition selection](#partition-selection)
    - [OOM / OOT auto-resubmit](#oom--oot-auto-resubmit)
    - [Checkpointing](#checkpointing)
    - [Informative emails](#informative-emails)
  - [ssbatch FAQ](#ssbatch-faq)
- [Using ssbatch with other pipeline managers](#using-ssbatch-with-other-pipeline-managers)
  - [Snakemake](#snakemake)
  - [Nextflow](#nextflow)
  - [Cromwell](#cromwell)
- [AI assistance (optional)](#ai-assistance-optional)
- [Reviewing and cleaning job records](#reviewing-and-cleaning-job-records)
- [sbatchAndTop](#sbatchandtop)
- [Upgrading](#upgrading)

---

## Features

- **Auto-sizes memory and run-time** from statistics of your earlier jobs.
- **Auto-selects the partition** that matches the requested run-time.
- **Auto-resubmits** jobs that die out-of-memory (OOM) or out-of-time (OOT), with doubled resources.
- **Optional checkpointing**: snapshot a long job before it hits its limit, then resume from the snapshot.
- **Informative emails**: Slurm emails are just a subject line; SmartSbatch attaches the job script, the exact submit command, and the stdout/stderr logs.
- **Optional [AI assistance](#ai-assistance-optional)**: explains why a job failed, reviews the fitted resource curves, and answers questions about a run. Everything works normally when AI is unavailable.

---

## Installation

```bash
# 1. Download SmartSbatch
git clone https://github.com/ld32/SmartSbatch.git $HOME/SmartSbatch

# 2. Put it on your PATH (add this line to ~/.bashrc to make it permanent)
export PATH=$HOME/SmartSbatch/bin:$PATH
```

**Optional** — only needed for the workflow-chart (`w`) option in `checkRun`:

```bash
module load conda/miniforge3/24.11.3-0
mamba create -n smartSlurmEnv -c conda-forge graphviz
```

> [!NOTE]
> The `module load conda/...` line is specific to an HPC that provides conda as an environment module. On other systems, activate conda however your site does. If your site uses a different conda module name, adjust it here and in `checkRun`.

---

# ssbatch: smart sbatch

For most programs, memory and run-time scale with input size. ssbatch records what resources prior jobs actually used, fits that relationship, and uses it to allocate resources for subsequent jobs.

<em><b>Figure 1</b> — Memory usage tracks input size, so input size is a good proxy for allocating memory.</em>
<div align="center">
<img src="https://github.com/ld32/SmartSbatch/blob/master/stats/back/findNumber.none.time.png" width="50%">
</div>

<em><b>Figure 2</b> — Early jobs run with the default memory; once enough have finished, ssbatch estimates memory for later jobs, sharply cutting wasted RAM.</em>
<div align="center">
<img src="https://github.com/ld32/SmartSbatch/blob/master/stats/back/barchartMem.png" width="50%">
</div>

<em><b>Figure 3</b> — The same for run-time: later jobs get much tighter time allocations.</em>
<div align="center">
<img src="https://github.com/ld32/SmartSbatch/blob/master/stats/back/barchartTime.png" width="50%">
</div>

## Usage

```
ssbatch [-P PROGRAM] [-I INPUTS] [-F FLAG] [SBATCH_OPTIONS] --wrap="COMMAND" [dryrun]
ssbatch [-P PROGRAM] [-I INPUTS] [-F FLAG] [SBATCH_OPTIONS] SCRIPT.sh [ARGS] [dryrun]
```

| Option | Description | Required |
|--------|-------------|----------|
| `-P PROGRAM` | Program name used to group resource statistics. If omitted, ssbatch derives it from the wrapped command or script name. | No |
| `-I INPUTS` | Input file(s)/dir(s), or an explicit size as `jobSize:N`. Drives resource estimation. | No |
| `-F FLAG` | Unique job identifier. If omitted, `program`+`input` (or a random suffix) is used. | No |
| `--wrap="CMD"` | Command to run. | Yes* |
| `SCRIPT.sh [ARGS]` | A script to run instead of `--wrap`. Its first line must be a shebang. | Yes* |
| `SBATCH_OPTIONS` | Any standard sbatch option (`-c`, `--mem`, `-t`, `-p`, `-A`, `--mail-user=`, …). Defaults exist for memory and time. | No |
| `dryrun` | As the **last** argument: not actually submit, only estimates and builds the job script but does not submit. | No |

<sub>*Provide **either** `--wrap` **or** a script file.</sub>

> [!TIP]
> None of `-P`, `-I`, `-F` is mandatory, but supplying `-P` (and `-I` when a meaningful input exists) is what lets ssbatch build good per-program statistics. Without `-I`, estimation falls back to the distribution of that program's past run-times/memory rather than a size-based fit.

## Quick example

```bash
# One-time setup
git clone https://github.com/ld32/SmartSbatch.git $HOME/SmartSbatch
export PATH=$HOME/SmartSbatch/bin:$PATH

# Make some test inputs
mkdir -p SmartSbatchTest && cd SmartSbatchTest
createNumberFiles.sh

# Run a few jobs so ssbatch can learn this program's memory/time profile.
# "findNumber" is just a label you choose with -P.
ssbatch -P findNumber -I numbers1.txt -F find1 --mem 4G -t 2:0:0 \
    --wrap="findNumber.sh 12345 numbers1.txt"

ssbatch -P findNumber -I numbers3.txt -F find3 --mem 4G -t 2:0:0 \
    --wrap="findNumber.sh 12345 numbers3.txt"

ssbatch -P findNumber -I numbers5.txt -F find5 --mem 4G -t 2:0:0 \
    --wrap="findNumber.sh 12345 numbers5.txt"
```

> [!IMPORTANT]
> Estimation needs **at least 3 completed records** for a given program/reference. Until then, jobs use the default memory and time. After 3 successful jobs, the next job is sized automatically — you can request `--mem 4G` and still see ssbatch submit it with, say, 21 M and a 13-minute limit.

```bash
# The 4th job is auto-sized from the first three:
ssbatch -P findNumber -I numbers2.txt -F find2 --mem 4G -t 2:0:0 \
    --wrap="findNumber.sh 12345 numbers2.txt"

# Multiple inputs are fine (their combined size is used):
ssbatch -P findNumber -I "numbers1.txt numbers2.txt" -F find12 --mem 4G -t 2:0:0 \
    --wrap="findNumber.sh 12345 numbers1.txt numbers2.txt"

# No -I? Estimation uses the 90th percentile of this program's past usage instead:
ssbatch -P findNumber -F find21 --mem 4G -t 2:0:0 \
    --wrap="findNumber.sh 12345 numbers2.txt"

# Check status
checkRun

# Cancel everything submitted from this directory
cancelAllJobs
```

> [!NOTE]
> Re-submitting a job with the **same program and input** that already succeeded will prompt you to confirm the rerun, so you don't silently repeat completed work.

## Utilities: unExport

`unExport` removes SmartSbatch from your `PATH` in the current shell, restoring the system `sbatch`:

```bash
source unExport; unExport
```

## checkRun: monitor and debug

`checkRun` is an interactive, three-level browser for job status and logs. **Run it from the directory where you ran `ssbatch`** (it needs the `.smartSlurm.log` file there).

```bash
checkRun
```

### Level 1 — pick a run

Lists each log folder/file with its job count; dry runs are flagged.

| Key | Action |
|-----|--------|
| *number* | Open that run |
| `r` | Reload (refresh the list and job states) |
| `h` | Show/hide runs that submitted no jobs |
| `q` | Quit |

### Level 2 — job status table

Shows every job from `allJobs.txt`, each with a colored status label:

| Label | Meaning |
|-------|---------|
| `Done` | finished successfully (`.success` exists) |
| `Fail` | finished with failure (`.failed` exists) |
| `Runn` | currently running |
| `Pend` | pending in the queue |
| `Requ` | was requeued (e.g. after OOM/OOT) |
| `Unkn` | no success/failure flag and not in the queue — often killed or a node failure |

| Key | Action |
|-----|--------|
| *number* | Open that job's log files (Level 3) |
| *number*`a` | Ask AI about that job (e.g. `1a`, `2a`) — see below |
| `?` | Ask AI about the whole run — see below |
| `w` | Render the dependency DAG as an image (needs graphviz; see below) |
| `p` | Show/hide pending jobs |
| `q` | Back to Level 1 |
| `qq` | Quit |

**Asking AI (`Na` and `?`)** — only offered when [AI is available](#ai-assistance-optional); the menu falls back to the plain keys otherwise.

`Na` tailors its question to the job's state, so it is useful on more than just failures:

| State | What AI is asked |
|-------|------------------|
| `Done` | Were the reserved memory and time a good fit for what was actually used? |
| `Fail` / `Unkn` | What went wrong, and how to fix it |
| `Runn` | Is it progressing or stuck, and will the reservation last? |
| `Pend` | What is it waiting for, and can it start sooner? (works with no `.out` log yet) |
| `Requ` | Why did the first attempt fail, and is the new reservation enough? |

`?` summarizes the whole run — what is finished, what is stuck, which step is the bottleneck, and what to do next — from the job counts, `allJobs.txt`, the live queue, and the logs of failed jobs.

### Level 3 — pick a log file

Lists the files for the selected job, tagged in plain language:

| Tag | File | Contents |
|-----|------|----------|
| `out` | `<flag>.out` | **stdout/stderr — start here to see the actual error** |
| `sh` | `<flag>.sh` | the generated Slurm script for the step |
| `adjust` | `<flag>.adjust` | resource-adjustment log |
| `success` / `failed` | flag files | status only, no contents |

| Key | Action |
|-----|--------|
| *number* | Open the file in `less` |
| `q` | Back to Level 2 |
| `qq` | Quit |

**Typical debugging flow**

```text
checkRun
  → [Level 1] pick your run
  → [Level 2] find the row labeled  Fail  or  Unkn
  → [Level 3] open its  out  log to read the error
```

**Workflow chart (`w`)** requires graphviz in the `smartSlurmEnv` conda environment (see [Installation](#installation)):

```bash
module load conda/miniforge3/24.11.3-0
conda activate smartSlurmEnv
```

`checkRun` then generates and displays a DAG of the jobs.

> [!NOTE]
> To keep things fast, `checkRun` caches the `squeue` result for ~2 minutes and a generated DAG for ~10 minutes. Use `r` at Level 1 to force a refresh.

## cancelAllJobs

Cancels all running and pending jobs that `ssbatch` submitted from the current directory:

```bash
cancelAllJobs
```

## How ssbatch works

### jobRecords.txt

A CSV of resource records for every successful job, one row per job. Its location is set by `smartSbatchJobRecordDir` in [`config.txt`](#configtxt) and defaults to `~/.SmartSbatch/jobRecords.txt`.

> [!WARNING]
> The file has **21 columns** (created with the header below). Estimation matches on **program (col 12)** and **reference (col 13)** and reads **memory used (col 7)** and **time used (col 8)**. Input size (col 2) is used for the size-vs-resource fit.

```text
1jobID,2inputSize,3memDefault,4timeDefault,5memAllocated,6timeAllocated,7memUsed,8timeUsed,9jobStatus,10userID,11saccMem,12program,13reference,14flag,15core,16extraMem,17extraTime,18memRatio,19timeRatio,20date,21epoch
```

| Col | Name | Col | Name | Col | Name |
|----:|------|----:|------|----:|------|
| 1 | jobID | 8 | **timeUsed** ⭐ | 15 | core |
| 2 | **inputSize** ⭐ | 9 | jobStatus | 16 | extraMem |
| 3 | memDefault | 10 | userID | 17 | extraTime |
| 4 | timeDefault | 11 | saccMem | 18 | memRatio |
| 5 | memAllocated | 12 | **program** ⭐ | 19 | timeRatio |
| 6 | timeAllocated | 13 | **reference** ⭐ | 20 | date |
| 7 | **memUsed** ⭐ | 14 | flag | 21 | epoch |

<sub>⭐ = used directly by resource estimation.</sub>

Example rows:

```text
93037,1465,2048,50,2048,50,89,1,COMPLETED,ld32,38,findNumber,none,1.0.findNumber.1,1,500,10,0.04,0.02,Thu Jun 25 05:33:48 PM EDT 2026,1782423228
93038,2930,2048,50,2048,50,87,2,COMPLETED,ld32,35,findNumber,none,1.0.findNumber.2,1,500,10,0.04,0.04,Thu Jun 25 05:34:32 PM EDT 2026,1782423272
93039,4395,2048,50,2048,50,104,3,COMPLETED,ld32,52,findNumber,none,1.0.findNumber.3,1,500,10,0.05,0.06,Thu Jun 25 05:35:17 PM EDT 2026,1782423317
```

### config.txt

Ships at `SmartSbatch/config/config.txt`. It defines the partition time limits, the `adjustPartition` function, and defaults such as where records and logs live.

> [!TIP]
> Copy it to `~/.SmartSbatch/config/config.txt` to override settings for just yourself. Your personal copy wins over the shared one — handy on a shared cluster. (SmartSbatch refuses to run if your personal copy is *older* than the shared one, to stop you using a stale config; run [`upgrade.sh`](#upgrading) to refresh it.)

Key settings:

```bash
export smartSbatchJobRecordDir=$HOME/.SmartSbatch  # where jobRecords.txt + stats live
export smartSlurmLogDir=smartSlurmLog            # per-run log dir (relative to your cwd)

export defaultMem=4096     # M   — used until estimation is available
export defaultTime=120     # min — used until estimation is available
export defaultExtraMem=500   # M   — safety margin added to estimates
export defaultExtraTime=10  # min — safety margin added to estimates

export partition1TimeLimit=720   # hours: run-time  >0h  and ≤12h
export partition2TimeLimit=7200  # hours: run-time >12h  and ≤5 days
export partition3TimeLimit=43200  # hours: run-time  >5d  and ≤30 days

adjustPartition() { ...; }
```

It also holds the `smartSlurmAi*` settings — see [AI assistance](#ai-assistance-optional).

### Resource estimation

Performed by `estimateResource.sh`. Two modes:

- **Input size given (`-I`)** — ssbatch fits a straight line to *input size vs. memory* and *input size vs. time* using past records, and reads the estimate off the fit. Needs **≥3 records** to fit; below that, it uses the defaults.
- **No input size** — ssbatch takes the **90th percentile** of this program's past memory and time (so ~90% of jobs finish within the allocation). Also needs **≥3 records**; below that, defaults.

Fitted plots are written under `$smartSbatchJobRecordDir/stats/` for inspection:

<div align="center">
<img src="https://github.com/ld32/SmartSbatch/blob/master/stats/back/findNumber.none.mem.png" width="45%" style="display:inline-block; margin-right:2%;">
<img src="https://github.com/ld32/SmartSbatch/blob/master/stats/back/findNumber.none.time.png" width="45%" style="display:inline-block; margin-left:2%;">
</div>

### Partition selection

`ssbatch` (via `adjustPartition` in `config.txt`) chooses a partition from the requested run-time using the `partitionNTimeLimit` values above. If you pass `-p` yourself and it doesn't fit the run-time, it is adjusted for you — so you generally don't need to specify `-p` at all.

### OOM / OOT auto-resubmit

When a job ends, `cleanUp.sh` records its memory and time usage into `jobRecords.txt`. If the job **failed out-of-memory or out-of-time**, ssbatch resubmits it with **double** the memory or time, and clears the stored formula for that program/reference so later jobs re-learn from fresh data.

### Checkpointing

Optional. When enabled (a `.Checkpoint` program name), a long-running job is snapshotted before it would hit its memory/time limit and resubmitted to resume from the checkpoint, instead of restarting from scratch.

### Informative emails

Slurm's own email is only a subject line. `cleanUp.sh` instead emails you the **job script**, the **exact submit command used**, and the **stdout/stderr logs** — enough to diagnose a failure without logging in. Use `noSuccEmail` (failures only) or `noEmail` (none) to reduce volume.

## ssbatch FAQ

<details>
<summary><b>Do I have to wait for the first jobs to finish before later jobs get estimated resources?</b></summary>

No — there is no waiting — each job is submitted immediately. Estimation simply kicks in once ≥3 records exist.
</details>

<details>
<summary><b>Are -P, -I, and -F optional?</b></summary>

Yes, all three.
- `-P` omitted → program name is taken from the wrapped command or the script name.
- `-I` omitted → estimation uses the program's past-usage distribution (90th percentile) instead of a size-based fit.
- `-F` omitted → the unique flag becomes `program`+`input`, or `program`+a random suffix.
</details>

<details>
<summary><b>Can -I take a size directly instead of a file?</b></summary>

Yes: `-I jobSize:12` — `12` is the input size (any integer). Useful when the meaningful "size" isn't a single file.
</details>

<details>
<summary><b>Can I pass -c and other sbatch options?</b></summary>

Yes. Any standard sbatch option works and is passed through.
</details>

<details>
<summary><b>How does ssbatch know a job already ran?</b></summary>

On success it creates `<flag>.success` in `smartSlurmLogDir`. That file's presence is how reruns are detected.
</details>

---

# Using ssbatch with other pipeline managers

Because `ssbatch` accepts standard sbatch syntax, you can point Snakemake, Nextflow, or Cromwell at it as their submit command and get smart sizing for free.

## Snakemake

```bash
git clone https://github.com/ld32/SmartSbatch.git $HOME/SmartSbatch

mkdir -p SmartSbatchTest && cd SmartSbatchTest
export PATH=$HOME/SmartSbatch/bin:$PATH

cp $HOME/SmartSbatch/bin/Snakefile .
cp $HOME/SmartSbatch/config/config.yaml .

module load conda/miniforge3/24.11.3-0
mamba env create --name snakemakeEnv --file $HOME/SmartSbatch/config/snakemakeEnv.yaml
conda activate snakemakeEnv

# Use ssbatch as the cluster submit command:
snakemake -p -j 999 --latency-wait=80 --cluster "ssbatch -t 100 --mem 1G -p short"

# With a specific Slurm account:
snakemake -p -j 999 --latency-wait=80 --cluster "ssbatch -A mySlurmAccount -t 100 --mem 1G"

checkRun
```

## Nextflow

```bash
git clone https://github.com/ld32/SmartSbatch.git $HOME/SmartSbatch

mkdir -p SmartSbatchTest && cd SmartSbatchTest
module load conda/miniforge3/24.11.3-0
mamba create -n nextflowEnv -c bioconda -y nextflow

export PATH=$HOME/SmartSbatch/bin:$HOME/SmartSbatch/sbatchBin:$PATH
conda activate nextflowEnv

cp $HOME/SmartSbatch/bin/nextflow.nf .
cp $HOME/SmartSbatch/config/nextflow.config .

# For a specific Slurm account, edit nextflow.config and uncomment/set:
#   process.clusterOptions = '--account=mySlurmAcc'

nextflow run nextflow.nf -profile slurm
checkRun

# When finished, restore the system sbatch:
export PATH="${PATH/:$HOME\/SmartSbatch\/sbatchBin/}"
```

## Cromwell

> [!NOTE]
> Cromwell support is planned and not yet documented.

---

# AI assistance (optional)

SmartSbatch can call a language model to explain failures and sanity-check its own estimates. **This is entirely optional.** Every AI call is guarded, so if AI is not set up — or is turned off, or the call fails or times out — each script behaves exactly as it did before: same emails, same estimates, same menus.

## Setup

AI calls go through a small setuid helper binary, `ai_call`, which holds the API token so it never appears in a script, a process list, or a log.

```bash
# Built and installed by an admin, typically at:
~/.SmartSbatch/bin/ai_call          # setuid (mode 4755), compiled from ai_call.c

# Access is granted per user by the helper's owner:
echo yourUserName >> ~/.SmartSbatch/allowed_users.txt
```

`ai_call` is found automatically at `~/.SmartSbatch/bin/ai_call`, then next to the SmartSbatch scripts. Set `smartSlurmAiCall` in [`config.txt`](#configtxt) to point somewhere else.

If it is missing, or your username is not in `allowed_users.txt`, SmartSbatch says so once and carries on without AI.

## What AI does, and when it runs

| Where | When it runs | What you get |
|---|---|---|
| `cleanUp.sh` (every job) | automatically, when a job ends **not** COMPLETED (Canceled excluded) | Failure analysis at the top of the job email, also saved to `smartSlurmLog/ai.<jobid>.txt` |
| `estimateResource.sh` | automatically, **only when a resource curve is rebuilt** and there are ≥ `smartSlurmAiMinRecords` records | Review of the fit: outliers, non-linearity, regime changes. Saved to `<recordDir>/stats/<program>.<ref>.aiReview.txt` and copied into the step's `.out` log |
| [`checkRun`](#checkrun-monitor-and-debug) | on demand: `1a`, `2a`, … or `?` | Per-job analysis (tailored to whether the job is done, failed, running or pending), or a summary of the whole run |
| [`reviewJobRecords.py`](#reviewing-and-cleaning-job-records) | on demand: `?` | Outliers and trends in a program's records, ending with a `SUGGESTED DELETIONS:` line |

`calculateMemTime.sh` runs on **every** submission, so it deliberately makes **no** AI call — it only prints a review that `estimateResource.sh` produced earlier.

> [!NOTE]
> Nothing is decided by AI. It never changes a resource estimate, deletes a record, cancels a job, or blocks a submission — it only writes text for you to read.

## Settings

All in [`config.txt`](#configtxt) (your `~/.SmartSbatch/config/config.txt` copy wins):

```bash
export smartSlurmAiEnabled=yes        # no = turn AI off completely
export smartSlurmAiCall=              # empty = auto-detect ai_call
export smartSlurmAiTimeout=90         # s, default cap for any AI call

export smartSlurmAiMinRecords=10      # records needed before a fitted curve is reviewed
export smartSlurmAiReviewTimeout=30   # s, curve review — short, a submission is waiting

export smartSlurmAiRecordReviewTimeout=180  # s, reviewJobRecords.py — you asked for it, so it may take longer
```

> [!TIP]
> Because `config.txt` is *sourced* (its `export`s override your environment), turn AI off by editing the config file — not with `smartSlurmAiEnabled=no ssbatch ...` on the command line.

Every timeout exists so AI can never delay a job or a submission: when it expires, the call is abandoned and the script continues.

## For developers

Two small libraries provide the guarded interface; use them rather than calling `ai_call` directly:

```bash
# bin/aiHelper.sh — shell
. "$(dirname $0)/aiHelper.sh"
aiEnabled || return            # false when AI is off, missing, or not permitted
echo "$prompt" | aiAsk         # prints the answer; on any failure prints nothing and returns non-zero
aiWhyNot                       # one-line reason, for a log or a menu
```

```python
# bin/aiHelper.py — python
import aiHelper
if aiHelper.ai_enabled():
    answer = aiHelper.ai_ask(prompt)   # str, or None on any failure
```

`aiAsk`/`ai_ask` never write a partial answer to stdout and never raise, so a caller can treat failure as simply "no AI today". Prompts are capped at 48 KB (`ai_call` rejects anything over 64 KB).

---

# Reviewing and cleaning job records

`reviewJobRecords.py` is a terminal-only tool (no browser, X11, or extra Python packages) for pruning outliers from your records so estimates stay accurate.

```bash
reviewJobRecords.py                    # the default job record
reviewJobRecords.py path/to/jobRecords.txt
```

How it works:

1. Pick a program from the numbered list.
2. An ASCII scatter plot of **Input Size (G)** vs **Memory (G)** is drawn, each point labeled `0`–`9` then `a`–`z`, with a table of Job IDs and exact values below.
3. Delete outliers by index — single `2`, list `1,4,7`, range `3-6`, or mixed `0,2-4,8`.
4. The plot redraws immediately; remaining points **keep their original indices** and the **axis scale stays fixed**, so numbering doesn't shift under you.
5. `?` asks [AI](#ai-assistance-optional) to review the records on screen — outliers, whether memory/time really track input size, and regime changes — ending with a line like `SUGGESTED DELETIONS: 8,9` that you can type straight back in. It only reads; nothing is deleted for you. (Shown only when AI is available.)
6. `b` back to the program list · `s` save (a timestamped backup is written first) · `q` quit.

> [!NOTE]
> Deletions only touch a working copy until you press `s`. Quitting without saving leaves `jobRecords.txt` untouched.

---

# sbatchAndTop

Submit a job with `ssbatch` and immediately run `scontrol top` on it:

```bash
export PATH=$HOME/SmartSbatch/bin:$PATH

sbatchAndTop -p short -c 1 -t 2:0:0 --mem 4G --wrap "my_application para1 para2"
# -p is optional — ssbatch picks the partition from the run-time.

# or with a script:
sbatchAndTop job.sh
```

---

# Upgrading

`backup your config.txt before upgrade`:

```bash
cd ~/SmartSbatch
cp ~/.SmartSbatch/config/config.txt ~/.SmartSbatch/config/config.txt.backup
git pull

# the modify the new config.txt manually
```
