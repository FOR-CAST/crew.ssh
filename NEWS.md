# crew.ssh 0.0.6

* `crew_controller_ssh()` gains `log_directory` and `log_join`, which capture each worker's output to a per-worker log file. The launcher previously probed for `crew`'s inherited log helpers, but those are defined only on `crew`'s *local* launcher (they read its `options_local`) and this class inherits from the base launcher, so the "fall back to discarding output" path was the only one ever taken and worker output was always discarded. Because the local `ssh` client's streams carry both the remote R process's output and `ssh`'s own diagnostics, a worker that dies with its connection now leaves a record instead of vanishing silently.

* The default `ssh_options` now set `ServerAliveCountMax` alongside `ServerAliveInterval`. Only the interval was set before, so OpenSSH's default count of 3 applied and the client abandoned a connection after 90 seconds of silence. A worker that loses its connection is terminated by `mirai`'s `autoexit`, and its task restarts from the beginning, so a brief stall on the control node could destroy every worker on every node at once and discard hours of work per worker. The new default tolerates 10 minutes.

# crew.ssh 0.0.5

* The bundled `sync-nodes.R` template restores the renv profiles listed in the new `crew.ssh.renv_profiles` option on each node, after the default profile (`RENV_PROFILE=<profile> <rscript> -e 'renv::restore(prompt = FALSE)'`, from `renv/profiles/<profile>/renv.lock` in the node's fast-forwarded checkout, so that lockfile must be committed and pushed). Before this, only the default profile was restored, so a profile that workers use (e.g. a separate library for one kind of task) was never updated on the nodes. The script stops before contacting any node if a listed name is not a plain profile name (`default`, `.` and `..` are rejected) or has no `renv/profiles/<profile>/renv.lock` in the project root.

# crew.ssh 0.0.4

* The bundled `sync-nodes.R` template now runs `git submodule sync` before `git submodule update` on each node, so a change to a submodule's URL in `.gitmodules` (e.g. repointing to a fork) is picked up. Without it, `git submodule update` kept using each node's previously-configured remote and failed to fetch the new pinned commit.

# crew.ssh 0.0.3

* The bundled `sync-nodes.R` template now provisions nodes **in parallel** (base `parallel::mclapply`, one fork per node) instead of one at a time. To keep a shared (networked) renv cache from being recompiled by every node at once, it preflights each node's OS codename, groups nodes by codename, restores the first node of each group first to warm the shared cache, then fans the rest of the group out in parallel to link it. Distinct codename groups warm concurrently. The control node is preflighted too: a group whose codename matches the control node skips the warm step (its cache is assumed already populated by the control node's own library) and fans out immediately. New `--force` flag fans a group out even if its warm node failed.

# crew.ssh 0.0.2

* `crew_ssh_monitor()` no longer crashes during long sessions: it polls nodes with concurrent `processx` child processes instead of forking the R session with `parallel::mclapply()` (forking from inside the running Shiny gadget is unsafe and intermittently errored on every node), and the renderer now degrades a failed poll to "unreachable" rather than erroring.

# crew.ssh 0.0.1

* `crew_ssh_monitor()` opens a live CPU and memory dashboard (a `miniUI` gadget, rendered in the Viewer pane) that polls each Linux node over SSH on a timer, so a running cluster can be watched in one window instead of an `htop` per machine; a no-dependency Bash equivalent is bundled at `system.file("templates/cluster-monitor.sh", package = "crew.ssh")`.

# crew.ssh 0.0.0.9000

* Initial experimental release.
* New `project-setup` vignette (integrating crew.ssh into a `targets`/`renv` project) plus a bundled, project-agnostic node-provisioning template at `system.file("templates/sync-nodes.R", package = "crew.ssh")`.
* `crew_class_launcher_ssh` is the underlying launcher; it places workers across nodes in proportion to their per-node capacities.
* `crew_controller_ssh()` creates a `crew` controller whose workers run on remote machines over SSH, for distributing `targets` pipelines across computers on a local network; `request_tty = TRUE` forces `ssh -tt` so the remote R exits when the local ssh client is killed; `tunnel = TRUE` dials the dispatcher back through an SSH reverse tunnel (`ssh -R`) so no inbound port needs to be open on the control node (suits firewalled networks).
* `crew_ssh_check()` preflight-checks each node over SSH (connectivity, project directory, resolved `Rscript` and R version, and package availability).
* `crew_ssh_node()` describes one remote machine (host, per-node worker capacity, and optional `rscript` / `projdir` / `ssh_options` overrides) for heterogeneous clusters.
