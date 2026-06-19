## Node specification + normalization for the SSH launcher.
##
## A "node" is one remote machine: a host name, a per-node worker capacity, and
## optional per-node overrides of the controller-level Rscript path, project
## directory, and ssh options. crew_controller_ssh() accepts either a named
## integer vector (host -> capacity) or a list of crew_ssh_node() objects.

#' Define an SSH worker node
#'
#' \strong{Experimental.} Describe one remote machine for
#' [crew_controller_ssh()]: its host name, the number of workers it may run, and
#' optional per-node overrides. Use a list of `crew_ssh_node()` objects (instead
#' of the shorthand named-integer `nodes` vector) when nodes differ in their
#' `Rscript` path, project directory, or ssh options.
#'
#' @param host Host name or IP of the remote machine, as understood by `ssh`
#'   (for example `"host1"` or `"user@host1"`).
#' @param workers Single positive integer: the per-node worker capacity (the
#'   maximum number of workers to place on this node).
#' @param rscript,projdir,ssh_options Optional per-node overrides of the
#'   controller-level defaults. `NULL` (the default) means inherit the value
#'   passed to [crew_controller_ssh()].
#'
#' @return A `crew_ssh_node` object (a named list).
#' @family ssh
#' @export
#' @examples
#' crew_ssh_node("host1", workers = 88L)
#' crew_ssh_node("host2", workers = 45L, rscript = "/opt/R/4.6.0/bin/Rscript")
crew_ssh_node <- function(host, workers, rscript = NULL, projdir = NULL, ssh_options = NULL) {
  if (!is.character(host) || length(host) != 1L || is.na(host) || !nzchar(host)) {
    stop("`host` must be a single non-empty string.", call. = FALSE)
  }
  workers <- suppressWarnings(as.integer(workers))
  if (length(workers) != 1L || is.na(workers) || workers < 1L) {
    stop("`workers` must be a single positive integer.", call. = FALSE)
  }
  structure(
    list(
      host = host,
      workers = workers,
      rscript = rscript,
      projdir = projdir,
      ssh_options = ssh_options
    ),
    class = "crew_ssh_node"
  )
}

## Resolve a NULL Rscript the way parallelly::makeClusterPSOCK() does: the
## launching session's own Rscript (a full path, so it does not depend on PATH or
## on rig-style version-suffixed names) when the cluster is homogeneous, else
## bare "Rscript" found on the remote PATH. Internal.
resolve_rscript <- function(rscript, homogeneous) {
  rscript %||% (if (isTRUE(homogeneous)) file.path(R.home("bin"), "Rscript") else "Rscript")
}

## Normalize the user `nodes` argument (a named integer vector or a list of
## crew_ssh_node objects) into a named list of fully-resolved specs: apply the
## controller-level rscript/projdir/ssh_options defaults (resolving a NULL
## rscript via `homogeneous`), validate, and key the list by host. Internal.
normalize_nodes <- function(nodes, rscript, projdir = NULL, ssh_options, homogeneous = TRUE) {
  if (is.numeric(nodes)) {
    nms <- names(nodes)
    if (is.null(nms) || any(!nzchar(nms))) {
      stop(
        "When `nodes` is a numeric vector it must be fully named ",
        "(host = capacity), e.g. c(node1 = 8L, node2 = 16L).",
        call. = FALSE
      )
    }
    nodes <- Map(function(h, w) crew_ssh_node(host = h, workers = w), nms, nodes)
  }
  if (!is.list(nodes) || length(nodes) == 0L) {
    stop(
      "`nodes` must be a named integer vector or a non-empty list of ",
      "`crew_ssh_node()` objects.",
      call. = FALSE
    )
  }
  nodes <- lapply(nodes, function(n) {
    if (!inherits(n, "crew_ssh_node")) {
      stop("Each element of `nodes` must be a `crew_ssh_node()` object.", call. = FALSE)
    }
    n$rscript <- resolve_rscript(n$rscript %||% rscript, homogeneous)
    n$projdir <- n$projdir %||% projdir
    n$ssh_options <- n$ssh_options %||% ssh_options
    ## `projdir` is required by callers that run code on the node (e.g.
    ## crew_controller_ssh(), crew_ssh_check()) but irrelevant to ones that only
    ## read system stats (crew_ssh_monitor()); validate it only when supplied.
    if (
      !is.null(n$projdir) &&
        (!is.character(n$projdir) ||
          length(n$projdir) != 1L ||
          is.na(n$projdir) ||
          !nzchar(n$projdir))
    ) {
      stop(
        "`projdir` must be supplied (per node or via the controller) as a ",
        "single non-empty string.",
        call. = FALSE
      )
    }
    n
  })
  hosts <- vapply(nodes, function(n) n$host, character(1L))
  if (anyDuplicated(hosts)) {
    dups <- unique(hosts[duplicated(hosts)])
    stop("Duplicate host(s) in `nodes`: ", paste(dups, collapse = ", "), ".", call. = FALSE)
  }
  names(nodes) <- hosts
  nodes
}
