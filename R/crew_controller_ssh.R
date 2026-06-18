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
#' * `host` set to a network address the worker nodes can reach (NOT
#'   `127.0.0.1`), with the chosen TCP port reachable.
#'
#' @param nodes Either a named integer vector mapping host names to per-node
#'   worker capacities (for example `c(node1 = 8L, node2 = 16L)`), or a list of
#'   [crew_ssh_node()] objects when nodes need different `rscript` / `projdir` /
#'   `ssh_options`. The controller's total `workers` is the sum of the per-node
#'   capacities, and workers are placed in proportion to them.
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
#'   before the host (for example `c("-o", "BatchMode=yes")`).
#' @param request_tty Logical: if `TRUE`, launch with `ssh -tt` (force a remote
#'   pseudo-tty) so the remote R is sent `SIGHUP` and exits when the local `ssh`
#'   client is killed. Useful for prompt teardown on hard kills, at the cost of
#'   merged / altered worker stdout-stderr capture. Default `FALSE`; the worker's
#'   own idle / wall timeouts already bound how long a stranded worker survives.
#'   Note this does not reap child processes the worker spawns (such as a
#'   `docker run` container); the worker code must tear those down itself.
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
#' }
crew_controller_ssh <- function(
  nodes,
  projdir,
  name = "ssh",
  rscript = NULL,
  homogeneous = TRUE,
  ssh_options = c("-o", "BatchMode=yes", "-o", "ServerAliveInterval=30"),
  request_tty = FALSE,
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
  nodes <- normalize_nodes(
    nodes,
    rscript = rscript,
    projdir = projdir,
    ssh_options = ssh_options,
    homogeneous = homogeneous
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
