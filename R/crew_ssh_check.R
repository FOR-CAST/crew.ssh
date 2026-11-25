## Preflight diagnostics: confirm each node is reachable over SSH, the project
## directory exists, the resolved Rscript runs, and the required packages load.
## This turns a silent "no workers ever started" hang into an actionable report.

## R expression run on each node to print its R version, the smallest memory.max
## of its own cgroup and the cgroups above it (cgroup v2; Inf if none is set), and,
## for each package name passed after `--args`, whether it is installed. It is
## passed through shQuote(), so it must not contain single quotes. Internal.
ssh_probe_expr <- paste(
  'cat(sprintf("R_VERSION=%s\\n", getRversion()))',
  paste0(
    "mm <- tryCatch({ ",
    'cg <- sub("^0::", "", grep("^0::", readLines("/proc/self/cgroup"), value = TRUE)[1L]); ',
    'p <- strsplit(cg, "/", fixed = TRUE)[[1L]]; p <- p[nzchar(p)]; ',
    'd <- c("", vapply(seq_along(p), function(k) paste(p[seq_len(k)], collapse = "/"), "")); ',
    'f <- file.path("/sys/fs/cgroup", d, "memory.max"); ',
    'v <- vapply(f, function(x) if (file.exists(x)) readLines(x, 1L) else "max", ""); ',
    "min(c(Inf, suppressWarnings(as.numeric(v))), na.rm = TRUE) ",
    "}, error = function(e) NA_real_)"
  ),
  'cat(sprintf("MEMORY_MAX=%.0f\\n", mm))',
  "pkgs <- commandArgs(trailingOnly = TRUE)",
  'for (p in pkgs) cat(sprintf("PKG=%s=%s\\n", p, requireNamespace(p, quietly = TRUE)))',
  sep = "; "
)

## Build the ssh args for the Rscript probe on one node:
##   c(<ssh options>, <host>, "cd <projdir> && <rscript> -e '<probe>' <pkgs>")
## The probe starts the way a worker does (remote_command()), so with a slice it
## runs in the slice, after the slice's limit is set. Package names are passed as
## trailing args and read via commandArgs(trailingOnly = TRUE); Rscript supplies
## its own `--args` separator, so we must NOT add one (doing so leaks a bogus
## "--args" entry into the probe). Pure + testable. Internal.
build_probe_args <- function(spec, packages = character()) {
  remote <- remote_command(spec, c("-e", shQuote(ssh_probe_expr), packages))
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
  memory_delegated <- NA
  memory_max_gb <- NA_real_
  missing_packages <- NA_character_
  detail <- ""

  conn <- run_ssh(c(spec$ssh_options, spec$host, "true"), timeout)
  ssh_ok <- identical(conn$status, 0L)

  if (!ssh_ok) {
    detail <- trimws(conn$stderr)
  } else {
    pd <- run_ssh(c(spec$ssh_options, spec$host, paste("test -d", shQuote(spec$projdir))), timeout)
    projdir_ok <- identical(pd$status, 0L)

    md <- run_ssh(c(spec$ssh_options, spec$host, memory_delegated_command), timeout)
    memory_delegated <- identical(md$status, 0L)

    pr <- run_ssh(build_probe_args(spec, packages), timeout)
    rscript_ok <- identical(pr$status, 0L)
    if (rscript_ok) {
      out <- strsplit(pr$stdout, "\n", fixed = TRUE)[[1]]
      version_line <- grep("^R_VERSION=", out, value = TRUE)
      if (length(version_line)) {
        r_version <- sub("^R_VERSION=", "", version_line[[1]])
      }
      memory_line <- grep("^MEMORY_MAX=", out, value = TRUE)
      if (length(memory_line)) {
        bytes <- suppressWarnings(as.numeric(sub("^MEMORY_MAX=", "", memory_line[[1]])))
        memory_max_gb <- round(bytes / 1024^3, 1)
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
    (is.null(spec$memory_max) || isTRUE(memory_delegated)) &&
    (is.na(missing_packages) || !nzchar(missing_packages))

  data.frame(
    host = spec$host,
    ssh = ssh_ok,
    projdir = projdir_ok,
    rscript = rscript_ok,
    r_version = r_version,
    memory_delegated = memory_delegated,
    memory_max_gb = memory_max_gb,
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
#' The `Rscript` probe starts the way a worker would, so with `slice` it runs in
#' the slice, and with `memory_max` it first sets the slice's limit on the node,
#' as a worker launch does (see the memory cap section of
#' [crew_controller_ssh()]). The `memory_max_gb` column is then the limit a worker
#' would see.
#'
#' @inheritParams crew_controller_ssh
#' @param packages Character vector of package names whose availability to check
#'   on each node (default `"crew"`, which every worker needs).
#' @param timeout Per-SSH-command timeout in seconds.
#'
#' @return A data frame (class `crew_ssh_check`), one row per node, with columns
#'   `host`, `ssh`, `projdir`, `rscript`, `r_version`, `memory_delegated`
#'   (whether the node's systemd user manager has the memory controller, which a
#'   `memory_max` needs), `memory_max_gb` (the smallest memory limit on the probe's
#'   cgroup and those above it, `Inf` if none is set), `missing_packages`, `ok`,
#'   and `detail` (diagnostic text for the first failing step). A node with a
#'   `memory_max` is `ok` only if `memory_delegated` is `TRUE`.
#' @family ssh
#' @export
#' @examples
#' \dontrun{
#' crew_ssh_check(
#'   nodes = c(host1 = 1L, host2 = 1L),
#'   projdir = "/home/me/myproject",
#'   packages = c("crew", "targets")
#' )
#'
#' ## also confirm the slice's limit reaches R on each node
#' crew_ssh_check(
#'   nodes = c(host1 = 1L, host2 = 1L),
#'   projdir = "/home/me/myproject",
#'   slice = "crew.slice",
#'   memory_max = "50%"
#' )
#' }
crew_ssh_check <- function(
  nodes,
  projdir,
  rscript = NULL,
  homogeneous = TRUE,
  ssh_options = c("-o", "BatchMode=yes", "-o", "ConnectTimeout=10"),
  packages = "crew",
  timeout = 30,
  slice = NULL,
  memory_max = NULL
) {
  nodes <- normalize_nodes(
    nodes,
    rscript = rscript,
    projdir = projdir,
    ssh_options = ssh_options,
    homogeneous = homogeneous,
    slice = slice,
    memory_max = memory_max
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
