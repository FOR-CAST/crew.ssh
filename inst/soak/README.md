# crew.ssh soak test

`run_soak.R` is a **manual** multi-node soak test (not run by `R CMD check` or
testthat). It launches workers across a real cluster, kills the workers on one
node mid-run to confirm `crew` relaunches them and all tasks still finish, tears
the controller down, and reports any orphaned worker processes per node.

Configure entirely via environment variables (no hostnames are hard-coded):

| variable | meaning |
|---|---|
| `CREW_SSH_TEST_NODES` | `"host1=2,host2=2"` (host = per-node cap) |
| `CREW_SSH_TEST_PROJDIR` | project dir on the nodes (shared / identical) |
| `CREW_SSH_TEST_HOST` | control-node address reachable from the worker nodes |
| `CREW_SSH_TEST_RSCRIPT` | optional Rscript override |
| `CREW_SSH_TEST_REQUEST_TTY` | `"true"` (default) / `"false"` (to expose orphans) |

Run on the control node:

```sh
CREW_SSH_TEST_NODES="host1=2,host2=2" \
CREW_SSH_TEST_PROJDIR="/path/to/project" \
CREW_SSH_TEST_HOST="control-node" \
Rscript -e 'source(system.file("soak/run_soak.R", package = "crew.ssh"))'
```

What to look for:

- All tasks complete despite the injected kill (crew relaunches the worker).
- "nodes used" spans multiple hosts (placement actually spread the work).
- 0 lingering `crew_worker` processes after teardown with `request_tty = TRUE`
  (with `false`, remote R may linger until its idle / wall timeout).
- No orphaned containers (the script prints a `docker ps` command to run per node;
  containers are never reaped by SSH / crew - the task code must do that).
