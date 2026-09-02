# crew.ssh

[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)

> **Experimental and private.**
> This package is **experimental**: the user-facing API may change without
> notice and it has not been hardened for production use.

A [`crew`](https://wlandau.github.io/crew/) launcher plugin that runs workers on
remote machines over **SSH**, so a [`targets`](https://docs.ropensci.org/targets/)
pipeline (or any `crew` workload) can be spread across several computers on a
trusted local network.

It is the lightweight counterpart to
[`crew.cluster`](https://wlandau.github.io/crew.cluster/) (which targets
traditional HPC schedulers such as SLURM/SGE/PBS/LSF): use `crew.ssh` for an
ad-hoc set of machines you can reach over SSH, with no scheduler in between.

## What it does

- Launches each `crew` worker as a remote R process via
  `ssh <host> "cd <projdir> && Rscript -e '<crew_worker call>'"`.
- Spreads workers across nodes **in proportion to per-node capacities**, so a
  single controller can drive heterogeneous machines (different RAM / CPU)
  without over-committing the smaller ones. See `?crew_class_launcher_ssh` for
  the placement rule.
- Plugs straight into `targets::tar_option_set(controller = ...)`, on its own or
  inside a `crew::crew_controller_group()`.

## Requirements

`crew.ssh` assumes a **trusted local network** and does no brokering of its own.
On every node you need:

- passwordless SSH (keys) from the control machine;
- the same project and R library reachable at `projdir` (e.g. a shared network
  filesystem, or identical local checkouts with the same package versions);
- `host` set to an address the worker nodes can reach (not `127.0.0.1`), with
  the dial-back TCP port reachable.

Workers are most robust as a **persistent** pool (`seconds_idle = Inf`, the
default): they launch once, stay up, and the `mirai` dispatcher feeds them tasks.

## Usage

```r
library(crew.ssh)

controller <- crew_controller_ssh(
  name = "primary",
  # host = capacity; sum is the total worker count, placement is proportional
  nodes = c(host1 = 45L, host2 = 88L),
  projdir = "/home/me/myproject",   # identical path on every node
  host = "control-node"             # reachable from the worker nodes
)
# `rscript` is not set above: with `homogeneous = TRUE` (the default) it resolves
# to this session's own Rscript (`file.path(R.home("bin"), "Rscript")`), so it
# works regardless of how R was installed (rig, system, conda, ...) as long as
# the path matches across nodes. This follows the `parallelly::makeClusterPSOCK()`
# convention. Set `homogeneous = FALSE` to use bare `Rscript` from the remote
# PATH, or override per node (below).

# drive a targets pipeline:
# targets::tar_option_set(controller = controller)
```

Heterogeneous nodes that differ in their `Rscript` path, project directory, or
SSH options can be described individually:

```r
controller <- crew_controller_ssh(
  nodes = list(
    crew_ssh_node("host1", workers = 88L),
    crew_ssh_node("host2", workers = 45L, rscript = "/opt/R/4.6.0/bin/Rscript")
  ),
  projdir = "/home/me/myproject",
  host = "control-node"
)
```

To route different kinds of work to different machines, build several
controllers and combine them with `crew::crew_controller_group()`, then select
per target with `targets::tar_resources_crew(controller = "<name>")`.

## Capacity and sizing

Per-node capacity is whatever a node can safely run at once for your workload.
For RAM-bound jobs, `cap = floor(usable_RAM / per_task_RAM)`. Because the
dispatcher mixes tasks across nodes and is **not** memory-aware, a single
controller must be sized for the heaviest task; split heavy and light work into
separate controllers (or separate targets) when their footprints differ a lot.

## Worker teardown and cleanup

On a normal stop, each worker exits gracefully, and its `seconds_idle` /
`seconds_wall` timeouts bound how long any stranded worker can survive. A *hard*
kill of the local `ssh` client does not by itself guarantee the remote R exits;
set `request_tty = TRUE` to launch with `ssh -tt`, so the remote receives
`SIGHUP` and dies with the client (the trade-off is merged / altered worker
stdout-stderr capture).

Important boundary: neither SSH nor `crew` reaps **child processes the worker
spawns** (for example a `docker run` container). If your tasks start such
processes, the worker code must tear them down itself (for example `docker run
--rm` plus killing the container when the R worker exits).

## Lifecycle

Experimental. Expect breaking changes. Known limitation: placement preserves
proportions but does not strictly re-enforce per-node caps under worker churn
(crashes / relaunches); strict enforcement for transient pools is planned.

## License

Apache License (>= 2).
