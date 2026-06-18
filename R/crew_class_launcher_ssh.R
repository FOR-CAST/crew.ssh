## SSH launcher plugin for crew.
##
## Subclass of crew::crew_class_launcher whose workers are remote R processes
## started over SSH. Each launch is placed on the node whose share of launched
## workers (launched / cap) is currently lowest, so that over sum(caps) launches
## every node receives exactly its capacity, and heterogeneous nodes share one
## controller in proportion to their `caps`. Build controllers with
## crew_controller_ssh(); this class is exported only for advanced use.

## Pick the node index whose launched-share (assigned / cap) is lowest. Over
## sum(caps) launches this gives each node exactly its capacity; ties go to the
## first (lowest-index) node. Internal.
weighted_pick <- function(assigned, caps) {
  which.min(assigned / caps)
}

## Build the argument vector for the `ssh` client that launches one worker:
##   c([-tt], <ssh options>, <host>, "cd <projdir> && <rscript> [r_arguments] -e '<call>'")
## `spec` is a normalized crew_ssh_node (host/rscript/projdir/ssh_options
## resolved); `call` is crew's crew_worker() call string. Paths and the call are
## shQuote()d for the remote shell. `request_tty` prepends `-tt` (force a remote
## pseudo-tty) so the remote R receives SIGHUP and dies when the local ssh client
## is killed. Pure + side-effect-free so it is unit-testable without spawning ssh.
## Internal.
build_ssh_args <- function(spec, call, r_arguments = NULL, request_tty = FALSE) {
  command <- c(shQuote(spec$rscript), r_arguments, "-e", shQuote(call))
  remote <- sprintf("cd %s && %s", shQuote(spec$projdir), paste(command, collapse = " "))
  tty <- if (isTRUE(request_tty)) "-tt"
  c(tty, spec$ssh_options, spec$host, remote)
}

#' SSH launcher class
#'
#' \strong{Experimental.} An [R6][R6::R6Class] subclass of
#' [crew::crew_class_launcher] whose workers are remote R processes started over
#' SSH. Construct controllers with [crew_controller_ssh()] rather than using this
#' class directly.
#'
#' @section Placement:
#' Each call to `launch_worker()` selects the node whose share of launched
#' workers (`launched / cap`) is currently lowest, so workers are distributed
#' across nodes in proportion to their per-node `caps`. With a persistent worker
#' pool (`seconds_idle = Inf`, the [crew_controller_ssh()] default) and
#' `workers = sum(caps)`, each node receives exactly its capacity and no node is
#' over-committed. Placement is by cumulative launch count, so under worker churn
#' (crashes / relaunches) the proportions are preserved but per-node caps are not
#' strictly re-enforced; strict enforcement for transient pools is a planned
#' enhancement.
#'
#' @section Worker teardown:
#' On normal shutdown the worker exits gracefully (the dispatcher closes the
#' connection, or `seconds_idle` / `seconds_wall` elapse), which also bounds how
#' long any stranded worker can survive. A *hard* kill of the local `ssh` client
#' does not by itself guarantee the remote R exits; set `request_tty = TRUE` in
#' [crew_controller_ssh()] to launch with `ssh -tt` so the remote receives
#' `SIGHUP` and dies with the client (at the cost of merged/altered stdout-stderr
#' capture). Note that any *child processes the worker spawns* (for example a
#' `docker run` container) are owned by their own service and are not reaped by
#' SSH or `crew`; the worker code is responsible for tearing those down.
#'
#' @family ssh
#' @export
crew_class_launcher_ssh <- R6Class(
  classname = "crew_class_launcher_ssh",
  inherit = crew::crew_class_launcher,
  public = list(
    #' @field nodes Named list of resolved [crew_ssh_node()] specifications,
    #'   keyed by host. Set by [crew_controller_ssh()].
    nodes = NULL,
    #' @field caps Named integer vector of per-node worker capacities. Set by
    #'   [crew_controller_ssh()].
    caps = NULL,
    #' @field request_tty Logical; if `TRUE`, launch with `ssh -tt` so the remote
    #'   R is killed when the local ssh client is. Set by [crew_controller_ssh()].
    request_tty = FALSE,
    #' @description Launch one worker as a remote R process over SSH.
    #' @param call Character string with the `crew::crew_worker()` call to run on
    #'   the worker (supplied by `crew`).
    #' @return A `processx` handle for the local `ssh` client process.
    launch_worker = function(call) {
      host <- private$.pick_node()
      spec <- self$nodes[[host]]
      name <- crew::crew_random_name()
      if (is.function(private$.log_prepare)) {
        private$.log_prepare()
      }
      ## build_ssh_args() cd's into projdir first so the remote .Rprofile / renv
      ## activate and relative paths resolve, then runs the crew_worker() call.
      processx::process$new(
        command = "ssh",
        args = build_ssh_args(spec, call, private$.r_arguments, self$request_tty),
        cleanup = TRUE,
        stdout = private$.log_path("stdout", name),
        stderr = private$.log_path("stderr", name)
      )
    }
  ),
  private = list(
    ## cumulative launches per node (named integer vector); lazily initialized
    ## from `caps` on first use so it can be set after construction.
    .assigned = NULL,
    .pick_node = function() {
      if (is.null(private$.assigned)) {
        private$.assigned <- self$caps * 0L
      }
      index <- weighted_pick(private$.assigned, self$caps)
      host <- names(self$caps)[index]
      private$.assigned[host] <- private$.assigned[host] + 1L
      host
    },
    ## Reuse crew's inherited per-worker log helpers when present (they capture
    ## the ssh client's stdout/stderr, which forwards the remote worker output);
    ## fall back to discarding output if a future crew version renames them.
    .log_path = function(which, name) {
      fn <- private[[paste0(".log_", which)]]
      if (is.function(fn)) {
        fn(name = name)
      } else {
        NULL
      }
    }
  )
)
