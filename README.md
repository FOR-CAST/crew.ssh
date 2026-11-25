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

## Capping memory per node

On machines that other people's jobs share, it can be agreed that a project's
workers use at most a fixed share of each machine's RAM, such as half. Sizing
`workers` from estimates of per-task memory does not hold that line, because a
task can need more than estimated. With `slice` and `memory_max`, the kernel
holds it:

```r
controller <- crew_controller_ssh(
  nodes = list(
    crew_ssh_node("host1", workers = 8L),   # no cap
    crew_ssh_node("host2", workers = 8L, slice = "myproject.slice", memory_max = "50%"),
    crew_ssh_node("host3", workers = 8L, slice = "myproject.slice", memory_max = "50%")
  ),
  projdir = "/home/me/myproject",
  tunnel = TRUE
)
```

Each worker on `host2` and `host3` then starts as `systemd-run --user --scope
--slice=myproject.slice <rscript> ...`, so a node's workers share one cgroup,
and before each start the slice gets `MemoryMax=50%` and `MemorySwapMax=0` via
`systemctl --user set-property --runtime`. The limit is on the slice, so it caps
the node's workers together, not each one. `slice` and `memory_max` can also be
set once on `crew_controller_ssh()` for every node.

- **What happens at the limit.** The kernel reclaims the slice's page cache,
  then kills one of its processes. A killed worker is reported by `crew` as a
  crash, and its task is retried up to `crashes_max` times; processes outside
  the slice are not touched. So keep `workers` x (peak memory of one worker)
  under `memory_max`: the cap protects the machine, it does not make the work
  fit.
- **Tools that size themselves from cgroup limits** (for example a worker that
  sets a raster library's memory budget from the limits of its own cgroup and
  those above it) see the slice's limit.
- **What it leaves on a node.** A runtime drop-in under
  `$XDG_RUNTIME_DIR/systemd/user.control/<slice>.d/`, removed at reboot or when
  the user's systemd manager stops. `systemctl --user revert <slice>` removes it
  sooner; `systemctl --user stop <slice>` stops every process in the slice. Each
  worker's scope is removed when the worker exits.
- **Requirement.** The node's systemd user manager must have the memory
  controller delegated to it, otherwise systemd accepts the limit and does not
  apply it. A launch refuses to start a worker on such a node, and
  `crew_ssh_check(..., slice = , memory_max = )` reports `memory_delegated` per
  node, along with `memory_max_gb`, the limit R sees from inside the slice.
- Enable lingering (`loginctl enable-linger`) on the nodes: without it, the
  user's systemd manager, and the slice's workers with it, stop when the user's
  last login session on that node ends.

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
