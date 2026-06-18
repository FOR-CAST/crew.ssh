## Preflight diagnostics: confirm each node is reachable over SSH, the project
## directory exists, the resolved Rscript runs, and the required packages load.
## This turns a silent "no workers ever started" hang into an actionable report.

## R expression run on each node to print its R version and, for each package
## name passed after `--args`, whether it is installed. Internal.
ssh_probe_expr <- paste(
  'cat(sprintf("R_VERSION=%s\\n", getRversion()))',
  "pkgs <- commandArgs(trailingOnly = TRUE)",
  'for (p in pkgs) cat(sprintf("PKG=%s=%s\\n", p, requireNamespace(p, quietly = TRUE)))',
  sep = "; "
)

## Build the ssh args for the Rscript probe on one node:
##   c(<ssh options>, <host>, "cd <projdir> && <rscript> -e '<probe>' --args <pkgs>")
## Pure + testable. Internal.
build_probe_args <- function(spec, packages = character()) {
  command <- c(shQuote(spec$rscript), "-e", shQuote(ssh_probe_expr))
  if (length(packages)) {
    command <- c(command, "--args", packages)
  }
  remote <- sprintf("cd %s && %s", shQuote(spec$projdir), paste(command, collapse = " "))
  c(spec$ssh_options, spec$host, remote)
}

## Run one ssh invocation, returning a list(status, stdout, stderr) and never
## throwing (timeouts/connect failures become a non-zero status). Internal.
run_ssh <- function(args, timeout) {
  tryCatch(
    processx::run("ssh", args, error_on_status = FALSE, timeout = timeout),
    error = function(e) list(status = 1L, stdout = "", stderr = conditionMessage(e))
  )
}

## Diagnose a single node: connectivity -> projdir -> Rscript/version/packages.
## Returns a one-row data.frame. Internal.
check_one_node <- function(spec, packages, timeout) {
  projdir_ok <- NA
  rscript_ok <- NA
  r_version <- NA_character_
  missing_packages <- NA_character_
  detail <- ""

  conn <- run_ssh(c(spec$ssh_options, spec$host, "true"), timeout)
  ssh_ok <- identical(conn$status, 0L)

  if (!ssh_ok) {
    detail <- trimws(conn$stderr)
  } else {
    pd <- run_ssh(c(spec$ssh_options, spec$host, paste("test -d", shQuote(spec$projdir))), timeout)
    projdir_ok <- identical(pd$status, 0L)

    pr <- run_ssh(build_probe_args(spec, packages), timeout)
    rscript_ok <- identical(pr$status, 0L)
    if (rscript_ok) {
      out <- strsplit(pr$stdout, "\n", fixed = TRUE)[[1]]
      version_line <- grep("^R_VERSION=", out, value = TRUE)
      if (length(version_line)) {
        r_version <- sub("^R_VERSION=", "", version_line[[1]])
      }
      missing <- character(0)
      for (line in grep("^PKG=", out, value = TRUE)) {
        kv <- sub("^PKG=", "", line)
        name <- sub("=.*$", "", kv)
        installed <- as.logical(sub("^[^=]*=", "", kv))
        if (!isTRUE(installed)) {
          missing <- c(missing, name)
        }
      }
      missing_packages <- paste(missing, collapse = ",")
    } else {
      detail <- trimws(pr$stderr)
    }
  }

  ok <- isTRUE(ssh_ok) &&
    isTRUE(projdir_ok) &&
    isTRUE(rscript_ok) &&
    (is.na(missing_packages) || !nzchar(missing_packages))

  data.frame(
    host = spec$host,
    ssh = ssh_ok,
    projdir = projdir_ok,
    rscript = rscript_ok,
    r_version = r_version,
    missing_packages = missing_packages,
    ok = ok,
    detail = detail,
    stringsAsFactors = FALSE
  )
}

#' Preflight-check SSH worker nodes
#'
#' \strong{Experimental.} For each node, verify over SSH (in order) that the host
#' is reachable, the project directory exists, the resolved `Rscript` runs (and
#' report its R version), and the required `packages` load. Use this before a run
#' to catch setup problems early, instead of debugging a pipeline that silently
#' launches no workers.
#'
#' @inheritParams crew_controller_ssh
#' @param packages Character vector of package names whose availability to check
#'   on each node (default `"crew"`, which every worker needs).
#' @param timeout Per-SSH-command timeout in seconds.
#'
#' @return A data frame (class `crew_ssh_check`), one row per node, with columns
#'   `host`, `ssh`, `projdir`, `rscript`, `r_version`, `missing_packages`, `ok`,
#'   and `detail` (diagnostic text for the first failing step).
#' @family ssh
#' @export
#' @examples
#' \dontrun{
#' crew_ssh_check(
#'   nodes = c(host1 = 1L, host2 = 1L),
#'   projdir = "/home/me/myproject",
#'   packages = c("crew", "targets")
#' )
#' }
crew_ssh_check <- function(
  nodes,
  projdir,
  rscript = NULL,
  homogeneous = TRUE,
  ssh_options = c("-o", "BatchMode=yes", "-o", "ConnectTimeout=10"),
  packages = "crew",
  timeout = 30
) {
  nodes <- normalize_nodes(
    nodes,
    rscript = rscript,
    projdir = projdir,
    ssh_options = ssh_options,
    homogeneous = homogeneous
  )
  rows <- lapply(nodes, check_one_node, packages = packages, timeout = timeout)
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  class(out) <- c("crew_ssh_check", "data.frame")
  out
}

#' @export
print.crew_ssh_check <- function(x, ...) {
  cat(sprintf("crew.ssh preflight: %d/%d node(s) OK\n", sum(x$ok), nrow(x)))
  print.data.frame(x, ...)
  invisible(x)
}
