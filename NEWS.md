# crew.ssh 0.0.0.9000

* Initial experimental release.
* `crew_class_launcher_ssh` is the underlying launcher; it places workers across nodes in proportion to their per-node capacities.
* `crew_controller_ssh()` creates a `crew` controller whose workers run on remote machines over SSH, for distributing `targets` pipelines across computers on a local network; `request_tty = TRUE` forces `ssh -tt` so the remote R exits when the local ssh client is killed.
* `crew_ssh_check()` preflight-checks each node over SSH (connectivity, project directory, resolved `Rscript` and R version, and package availability).
* `crew_ssh_node()` describes one remote machine (host, per-node worker capacity, and optional `rscript` / `projdir` / `ssh_options` overrides) for heterogeneous clusters.
