## User-facing constructor: a crew controller whose workers run over SSH.

#' Create a 'crew' controller with SSH workers
#'
#' \strong{Experimental.} Build a [crew::crew_controller] whose workers run on
#' remote machines over SSH, for distributing a `targets` pipeline (or any
#' `crew` workload) across several computers on a trusted local network. Workers
#' are placed across nodes in proportion to per-node capacities (`caps`), so
#' heterogeneous machines can share a single controller. See [crew_ssh_node()]
#' for per-node overrides and [crew_class_launcher_ssh] for the placement rule.
#'
#' @section Requirements:
#' Each worker is launched with `ssh <host> "cd <projdir> && <rscript> -e
#' '<crew_worker call>'"` and must be able to dial back into the controller over
#' the network. In practice this needs:
#' * passwordless SSH (keys) from the control machine to every node;
#' * the same project + R library reachable at `projdir` on every node (for
#'   example a shared network filesystem, or identical local checkouts);
#' * for direct dial-back (`tunnel = FALSE`): `host` set to an address the worker
#'   nodes can reach (NOT `127.0.0.1`) with the dispatcher's TCP port reachable;
#' * for `tunnel = TRUE`: nothing extra -- the dial-back rides the SSH connection,
#'   so no inbound port is opened (best for firewalled networks).
#'
#' @param nodes Either a named integer vector mapping host names to per-node
#'   worker capacities (for example `c(node1 = 8L, node2 = 16L)`), or a list of
#'   [crew_ssh_node()] objects when nodes need different `rscript` / `projdir` /
#'   `ssh_options` / `slice` / `memory_max`. The controller's total `workers` is
#'   the sum of the per-node capacities, and workers are placed in proportion to
#'   them.
#' @param projdir Path to the project directory on the remote nodes (identical
#'   across nodes unless overridden per node via [crew_ssh_node()]). Each worker
#'   runs `cd <projdir>` first so the project `.Rprofile` / `renv` activate and
#'   relative paths resolve.
#' @param rscript Name or path of the `Rscript` executable on the remote nodes.
#'   `NULL` (the default) is resolved per `homogeneous`, mirroring the
#'   [parallelly::makeClusterPSOCK()] convention: the launching session's own
#'   `Rscript` (`file.path(R.home("bin"), "Rscript")`, a full path that does not
#'   depend on the remote `PATH` or on rig-style version-suffixed names) when
#'   `homogeneous = TRUE`, or bare `"Rscript"` found on the remote `PATH` when
#'   `homogeneous = FALSE`. Override per node via [crew_ssh_node()].
#' @param homogeneous Logical: do all nodes share the same R installation path as
#'   the control machine? This is the package's default assumption and controls
#'   how a `NULL` `rscript` is resolved. Set `FALSE` for mixed installs (then the
#'   remote `PATH` must provide `Rscript`, or set `rscript` per node).
#' @param ssh_options Character vector of options passed to the `ssh` client
#'   before the host (for example `c("-o", "BatchMode=yes")`). Each function's
#'   own default differs; see its usage.
#' @param log_directory Directory for per-worker log files, or `NULL` (the
#'   default) to discard worker output. Each worker's `ssh` client writes the
#'   remote R process's output here, along with `ssh`'s own diagnostics, which is
#'   the only record of why a worker died. Set it for any long run.
#' @param log_join Logical: if `TRUE` (default), a worker's standard error is
#'   merged into its single log file; if `FALSE`, the two streams are written to
#'   separate `-stdout` / `-stderr` files.
#' @param slice Name of a systemd user slice on the remote nodes, ending in
#'   `.slice` (for example `"crew.slice"`), or `NULL` (the default) to run R
#'   directly. With a slice, each R process is started as `systemd-run --user
#'   --scope --slice=<slice> <rscript> ...`, so all of a node's R processes share
#'   the slice's cgroup and any limit set on it. As in systemd, a `-` nests a
#'   slice in another (`a-b.slice` is inside `a.slice`). Override per node via
#'   [crew_ssh_node()].
#' @param memory_max Memory limit for the slice on each node, in the syntax of
#'   systemd's `MemoryMax=`: a size in bytes with an optional `K`, `M`, `G` or
#'   `T` suffix (`"488G"`), or a percentage of the node's RAM (`"50%"`). Requires
#'   `slice`. Before each R process starts, the slice gets `MemoryMax=` and
#'   `MemorySwapMax=0`, and the process is not started if the node's systemd user
#'   manager cannot enforce them. `NULL` (the default) sets no limit. Override
#'   per node via [crew_ssh_node()].
#' @param request_tty Logical: if `TRUE`, launch with `ssh -tt` (force a remote
#'   pseudo-tty) so the remote R is sent `SIGHUP` and exits when the local `ssh`
#'   client is killed. Useful for prompt teardown on hard kills, at the cost of
#'   merged / altered worker stdout-stderr capture. Default `FALSE`; the worker's
#'   own idle / wall timeouts already bound how long a stranded worker survives.
#'   Note this does not reap child processes the worker spawns (such as a
#'   `docker run` container); the worker code must tear those down itself.
#' @param tunnel Logical: if `TRUE`, workers dial the dispatcher back through an
#'   SSH reverse tunnel (`ssh -R`) instead of a direct TCP connection, so NO
#'   inbound port needs to be open on the control node (ideal for firewalled
#'   networks, and more secure -- the dispatcher binds `127.0.0.1` only). Forces
#'   `host = "127.0.0.1"` (any supplied `host` is ignored). Default `FALSE`.
#' @param name Character of length 1, name of the controller.
#' @param host Local (control-node) host name or IP that remote workers dial
#'   back into. Must be reachable from the worker nodes.
#' @param port TCP port for workers to dial back into. `NULL` chooses a free
#'   ephemeral port.
#' @inheritParams crew::crew_controller_local
#'
#' @return A `crew` controller object (see [crew::crew_controller_local()]),
#'   ready to pass to `targets::tar_option_set(controller = ...)` or to combine
#'   in a [crew::crew_controller_group()].
#' @section Connection keepalive:
#' The default `ssh_options` set `ServerAliveInterval` and `ServerAliveCountMax`
#' together, and both matter. A worker whose `ssh` client gives up loses its
#' connection to the dispatcher, `mirai`'s `autoexit` then terminates the
#' worker, and whatever it was computing restarts from the beginning. With only
#' the interval set, OpenSSH's default `ServerAliveCountMax` of 3 tears the
#' connection down after 90 seconds of silence -- and since a stall on the
#' control node affects every connection at once, one brief hiccup can destroy
#' every worker on every node simultaneously. The default here tolerates 10
#' minutes, on the reasoning that waiting longer on a genuinely dead node costs
#' only the wait, while abandoning a live one costs all of its work so far.
#'
#' These are passed as `ssh -o`, which takes precedence over `~/.ssh/config` and
#' `/etc/ssh/ssh_config` for those two keys only; every other setting for the
#' host (`Hostname`, `Port`, `User`, `IdentityFile`, `ProxyJump` and so on) still
#' comes from those files. Note that supplying `ssh_options` REPLACES this
#' default vector rather than adding to it, so a caller who sets it takes on
#' responsibility for the keepalive settings too.
#'
#' @section Memory cap per node:
#' With `slice` and `memory_max`, the workers on a node are held, together, to
#' `memory_max`: the limit is on the slice, not on each worker. The kernel
#' enforces it, so it holds however much memory a task turns out to need. When
#' the slice's processes reach the limit the kernel first reclaims their page
#' cache, then kills one of them, so the cost of an undersized limit is a killed
#' worker (which `crew` reports as a crash) rather than a node short of memory
#' for everything else on it. `MemorySwapMax=0` stops the slice from swapping
#' instead. Size the workers to fit: a node's `workers` times the peak memory of
#' one worker should stay under `memory_max`. Processes that read their cgroup's
#' limits to size their own memory use see the slice's limit among them.
#'
#' The limit is set with `systemctl --user set-property --runtime <slice>
#' MemoryMax=<memory_max> MemorySwapMax=0` before each worker starts. This is
#' idempotent, works whether or not the slice exists yet, and changes the limit
#' of a slice already running. Every controller or user of the same slice name on
#' a node shares the one limit, and the last value set applies to all of them.
#' It leaves a drop-in under `$XDG_RUNTIME_DIR/systemd/user.control/<slice>.d/`
#' on the node, which goes away when the node reboots or the user's systemd
#' manager stops; `systemctl --user revert <slice>` removes it sooner, and
#' `systemctl --user stop <slice>` stops every process in the slice. Each worker
#' runs in its own transient scope, which is removed when the worker exits.
#'
#' The node's systemd user manager must have the memory controller delegated to
#' it, or the limit would be accepted and have no effect; a worker is not started
#' on a node where it is not. [crew_ssh_check()] reports this per node. Where the
#' user has no lingering systemd manager on a node (`loginctl enable-linger`), the
#' manager stops once the user's last login session there ends, and the slice's
#' processes stop with it.
#'
#' @family ssh
#' @export
#' @examples
#' \dontrun{
#' controller <- crew_controller_ssh(
#'   name = "primary",
#'   nodes = c(host1 = 45L, host2 = 88L),
#'   projdir = "/home/me/myproject",
#'   host = "control-node"
#'   # rscript defaults to this session's Rscript (homogeneous installs)
#' )
#'
#' ## hold each node's workers, together, to half of its RAM
#' controller <- crew_controller_ssh(
#'   nodes = c(host1 = 45L, host2 = 88L),
#'   projdir = "/home/me/myproject",
#'   tunnel = TRUE,
#'   slice = "crew.slice",
#'   memory_max = "50%"
#' )
#' }
crew_controller_ssh <- function(
  nodes,
  projdir,
  name = "ssh",
  rscript = NULL,
  homogeneous = TRUE,
  ssh_options = c(
    "-o",
    "BatchMode=yes",
    "-o",
    "ServerAliveInterval=30",
    "-o",
    "ServerAliveCountMax=20"
  ),
  request_tty = FALSE,
  tunnel = FALSE,
  log_directory = NULL,
  log_join = TRUE,
  slice = NULL,
  memory_max = NULL,
  host = NULL,
  port = NULL,
  tls = crew::crew_tls(),
  serialization = NULL,
  profile = crew::crew_random_name(),
  seconds_interval = 0.5,
  seconds_timeout = 60,
  seconds_launch = 60,
  seconds_idle = Inf,
  seconds_wall = Inf,
  tasks_max = Inf,
  tasks_timers = 0L,
  reset_globals = TRUE,
  reset_packages = FALSE,
  reset_options = FALSE,
  garbage_collection = FALSE,
  crashes_max = 5L,
  r_arguments = NULL,
  options_metrics = crew::crew_options_metrics()
) {
  if (isTRUE(tunnel)) {
    if (!is.null(host) && !host %in% c("127.0.0.1", "localhost")) {
      message(
        "crew.ssh: tunnel = TRUE binds the dispatcher to 127.0.0.1 (ignoring host = '",
        host,
        "')."
      )
    }
    host <- "127.0.0.1"
  }
  nodes <- normalize_nodes(
    nodes,
    rscript = rscript,
    projdir = projdir,
    ssh_options = ssh_options,
    homogeneous = homogeneous,
    slice = slice,
    memory_max = memory_max
  )
  caps <- vapply(nodes, function(n) n$workers, integer(1L))
  client <- crew::crew_client(
    host = host,
    port = port,
    tls = tls,
    serialization = serialization,
    profile = profile,
    seconds_interval = seconds_interval,
    seconds_timeout = seconds_timeout
  )
  launcher <- crew_class_launcher_ssh$new(
    name = name,
    workers = sum(caps),
    seconds_interval = seconds_interval,
    seconds_timeout = seconds_timeout,
    seconds_launch = seconds_launch,
    seconds_idle = seconds_idle,
    seconds_wall = seconds_wall,
    tasks_max = tasks_max,
    tasks_timers = tasks_timers,
    tls = tls,
    r_arguments = r_arguments,
    options_metrics = options_metrics
  )
  launcher$nodes <- nodes
  launcher$caps <- caps
  launcher$request_tty <- request_tty
  launcher$tunnel <- tunnel
  launcher$log_directory <- log_directory
  launcher$log_join <- log_join
  controller <- crew::crew_controller(
    client = client,
    launcher = launcher,
    reset_globals = reset_globals,
    reset_packages = reset_packages,
    reset_options = reset_options,
    garbage_collection = garbage_collection,
    crashes_max = crashes_max
  )
  controller$validate()
  controller
}
