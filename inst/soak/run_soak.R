# Manual multi-node soak test for crew.ssh. NOT run by R CMD check or testthat.
#
# It launches workers across the real cluster, injects a fault (kills the workers
# on one node mid-run) to confirm crew relaunches and all tasks still finish, then
# tears the controller down and checks each node for orphaned worker processes.
#
# Configure via the environment (no hostnames are hard-coded):
#   CREW_SSH_TEST_NODES        "host1=2,host2=2,..."  (host=per-node cap)
#   CREW_SSH_TEST_PROJDIR      project dir path on the nodes (shared/identical)
#   CREW_SSH_TEST_HOST         control-node address reachable from worker nodes
#   CREW_SSH_TEST_RSCRIPT      optional Rscript path override
#   CREW_SSH_TEST_REQUEST_TTY  "true" (default) or "false" (to expose orphans)
#
# Run ON THE CONTROL NODE:
#   Rscript -e 'source(system.file("soak/run_soak.R", package = "crew.ssh"))'
# or directly on the source tree:
#   Rscript packages/crew.ssh/inst/soak/run_soak.R

library(crew.ssh)

env <- function(x, default = "") {
  v <- Sys.getenv(x)
  if (nzchar(v)) v else default
}

stopifnot(
  "CREW_SSH_TEST_NODES not set" = nzchar(env("CREW_SSH_TEST_NODES")),
  "CREW_SSH_TEST_PROJDIR not set" = nzchar(env("CREW_SSH_TEST_PROJDIR")),
  "CREW_SSH_TEST_HOST not set" = nzchar(env("CREW_SSH_TEST_HOST"))
)

parse_nodes <- function(x) {
  pairs <- trimws(strsplit(x, ",", fixed = TRUE)[[1]])
  pairs <- pairs[nzchar(pairs)]
  kv <- strsplit(pairs, "=", fixed = TRUE)
  caps <- as.integer(vapply(kv, `[`, character(1L), 2L))
  names(caps) <- vapply(kv, `[`, character(1L), 1L)
  caps
}

nodes <- parse_nodes(env("CREW_SSH_TEST_NODES"))
projdir <- env("CREW_SSH_TEST_PROJDIR")
host <- env("CREW_SSH_TEST_HOST")
rscript <- env("CREW_SSH_TEST_RSCRIPT")
rscript <- if (nzchar(rscript)) rscript else NULL
request_tty <- !identical(tolower(env("CREW_SSH_TEST_REQUEST_TTY", "true")), "false")
ssh_opts <- c("-o", "BatchMode=yes", "-o", "ConnectTimeout=10")

# `[c]rew_worker` bracket trick: matches the worker cmdline but not the pkill/pgrep
# command itself (which would otherwise self-match).
worker_pat <- "[c]rew_worker"

cat(sprintf(
  "crew.ssh soak: nodes=%s projdir=%s host=%s request_tty=%s\n",
  paste(names(nodes), nodes, sep = "=", collapse = ","),
  projdir,
  host,
  request_tty
))

controller <- crew_controller_ssh(
  name = "soak",
  nodes = nodes,
  projdir = projdir,
  host = host,
  rscript = rscript,
  ssh_options = ssh_opts,
  request_tty = request_tty,
  seconds_idle = 30
)
controller$start()

n_tasks <- 6L * sum(nodes)
cat(sprintf("pushing %d tasks (each sleeps ~15s)...\n", n_tasks))
for (i in seq_len(n_tasks)) {
  controller$push(
    command = {
      Sys.sleep(15)
      Sys.info()[["nodename"]]
    },
    name = sprintf("t%03d", i)
  )
}

# let workers spin up and start running, then kill the workers on one node
Sys.sleep(25)
victim <- names(nodes)[[1]]
cat(sprintf("FAULT INJECTION: killing crew workers on '%s'...\n", victim))
system2(
  "ssh",
  c(ssh_opts, victim, sprintf("pkill -u $USER -f '%s'", worker_pat)),
  stdout = FALSE,
  stderr = FALSE
)

cat("waiting for all tasks to complete (crew should relaunch the killed worker)...\n")
controller$wait(seconds_timeout = 1800)

results <- character(0)
errors <- 0L
repeat {
  task <- controller$pop()
  if (is.null(task)) {
    break
  }
  err <- task$error[[1]]
  if (is.null(err) || is.na(err)) {
    results <- c(results, task$result[[1]])
  } else {
    errors <- errors + 1L
    cat(sprintf("  task error: %s\n", err))
  }
}

cat(sprintf(
  "\nRESULT: %d/%d tasks completed (%d errors); nodes used: %s\n",
  length(results),
  n_tasks,
  errors,
  paste(sort(unique(results)), collapse = ", ")
))
try(print(controller$summary()), silent = TRUE)

cat("terminating controller...\n")
controller$terminate()
Sys.sleep(10)

cat("\n=== orphan check: lingering worker processes per node (expect 0) ===\n")
for (h in names(nodes)) {
  out <- system2(
    "ssh",
    c(ssh_opts, h, sprintf("pgrep -u $USER -af '%s'", worker_pat)),
    stdout = TRUE,
    stderr = FALSE
  )
  cat(sprintf("[%s] %d lingering crew_worker process(es)\n", h, length(out)))
  if (length(out)) {
    cat(paste0("    ", out, collapse = "\n"), "\n")
  }
}

cat("\nAlso check for orphaned containers, e.g.:\n")
cat(sprintf(
  "  for h in %s; do echo \"== $h ==\"; ssh $h docker ps; done\n",
  paste(names(nodes), collapse = " ")
))
cat("\nInterpretation:\n")
cat("- All tasks should complete despite the killed worker (crew relaunches it).\n")
cat("- With request_tty = TRUE, terminate() should leave 0 lingering remote R.\n")
cat("- With request_tty = FALSE, remote R may linger until its idle/wall timeout.\n")
cat("- Containers (docker run) are never reaped by SSH/crew; the task code must.\n")
