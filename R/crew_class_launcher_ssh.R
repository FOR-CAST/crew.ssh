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

## Extract the dispatcher TCP port from a crew_worker() call's url
## (tcp://127.0.0.1:PORT or tcp://localhost:PORT); NA_integer_ if not found.
## Used only in reverse-tunnel mode. Internal.
dispatcher_port <- function(call) {
  m <- regmatches(call, regexpr("tcp://(?:127\\.0\\.0\\.1|localhost):[0-9]+", call, perl = TRUE))
  if (!length(m)) {
    return(NA_integer_)
  }
  as.integer(sub(".*:", "", m))
}

## Rewrite the url port in a crew_worker() call so the worker dials its node-local
## reverse-tunnel port instead of the dispatcher port directly. Internal.
rewrite_url_port <- function(call, from_port, to_port) {
  sub(
    sprintf("(tcp://(?:127\\.0\\.0\\.1|localhost):)%d\\b", from_port),
    sprintf("\\1%d", to_port),
    call,
    perl = TRUE
  )
}

## Build the argument vector for the `ssh` client that launches one worker:
##   c([-tt], [-R <fwd> -o ExitOnForwardFailure=yes], <ssh options>, <host>,
##     "cd <projdir> && <rscript> [r_arguments] -e '<call>'")
## `spec` is a normalized crew_ssh_node (host/rscript/projdir/ssh_options
## resolved); `call` is crew's crew_worker() call string. Paths and the call are
## shQuote()d for the remote shell. `request_tty` prepends `-tt` (force a remote
## pseudo-tty) so the remote R receives SIGHUP and dies when the local ssh client
## is killed. `tunnel` (e.g. "49152:127.0.0.1:55000") adds a reverse port-forward
## so the worker dials the dispatcher back over the ssh connection (no inbound
## port needed). Pure + side-effect-free so it is unit-testable. Internal.
build_ssh_args <- function(spec, call, r_arguments = NULL, request_tty = FALSE, tunnel = NULL) {
  command <- c(shQuote(spec$rscript), r_arguments, "-e", shQuote(call))
  remote <- sprintf("cd %s && %s", shQuote(spec$projdir), paste(command, collapse = " "))
  tty <- if (isTRUE(request_tty)) "-tt"
  forward <- if (!is.null(tunnel)) c("-R", tunnel, "-o", "ExitOnForwardFailure=yes")
  c(tty, forward, spec$ssh_options, spec$host, remote)
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
#' @section Reverse-tunnel dial-back:
#' With `tunnel = TRUE` (in [crew_controller_ssh()]) the dispatcher binds
#' `127.0.0.1` and each worker is launched with `ssh -R <node-port>:127.0.0.1:<dispatcher-port>`,
#' so the worker dials a node-local port that is forwarded back to the dispatcher
#' over the existing SSH connection. No inbound firewall port is opened on the
#' control node, which suits locked-down networks. Each worker gets a distinct
#' node-local port (so co-located workers do not collide) and the tunnel lives
#' and dies with that worker's `ssh` process.
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
    #' @field tunnel Logical; if `TRUE`, the worker dials the dispatcher back
    #'   through an SSH reverse tunnel (no inbound port needed). Requires the
    #'   dispatcher on `127.0.0.1`. Set by [crew_controller_ssh()].
    tunnel = FALSE,
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
      tunnel <- NULL
      if (isTRUE(self$tunnel)) {
        dport <- dispatcher_port(call)
        if (is.na(dport)) {
          stop(
            "crew.ssh: cannot determine the dispatcher port for the reverse ",
            "tunnel; the controller host must be '127.0.0.1' (use ",
            "crew_controller_ssh(tunnel = TRUE)).",
            call. = FALSE
          )
        }
        ## worker dials its node-local port; ssh -R forwards it to the dispatcher.
        rport <- private$.next_tunnel_port()
        call <- rewrite_url_port(call, dport, rport)
        tunnel <- sprintf("%d:127.0.0.1:%d", rport, dport)
      }
      ## build_ssh_args() cd's into projdir first so the remote .Rprofile / renv
      ## activate and relative paths resolve, then runs the crew_worker() call.
      processx::process$new(
        command = "ssh",
        args = build_ssh_args(spec, call, private$.r_arguments, self$request_tty, tunnel),
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
    ## monotonic counter -> a distinct node-local reverse-tunnel port per launch
    ## (private/dynamic range 49152-59151) so co-located workers never collide.
    .tunnel_counter = 0L,
    .next_tunnel_port = function() {
      private$.tunnel_counter <- private$.tunnel_counter + 1L
      49152L + ((private$.tunnel_counter - 1L) %% 10000L)
    },
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
