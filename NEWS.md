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
