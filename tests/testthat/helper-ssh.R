# Test helpers for the (opt-in) SSH integration tests.

# TRUE if passwordless `ssh localhost true` works (no prompt, quick).
local_ssh_available <- function() {
  if (Sys.which("ssh") == "") {
    return(FALSE)
  }
  status <- tryCatch(
    processx::run(
      "ssh",
      c("-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "localhost", "true"),
      error_on_status = FALSE,
      timeout = 15
    )$status,
    error = function(e) 1L
  )
  identical(status, 0L)
}

# Skip unless the user opted in (CREW_SSH_TEST_INTEGRATION) AND localhost SSH
# works. Integration tests actually launch a worker over ssh, so they are off by
# default (local dev, CRAN) and enabled in CI.
skip_if_no_local_ssh <- function() {
  testthat::skip_if_not(
    nzchar(Sys.getenv("CREW_SSH_TEST_INTEGRATION")),
    "set CREW_SSH_TEST_INTEGRATION to run SSH integration tests"
  )
  testthat::skip_if_not(local_ssh_available(), "passwordless `ssh localhost` is not available")
}

# Parse CREW_SSH_TEST_NODES ("host1=2,host2=3") into a named integer vector.
crew_ssh_test_nodes <- function() {
  pairs <- trimws(strsplit(Sys.getenv("CREW_SSH_TEST_NODES"), ",", fixed = TRUE)[[1]])
  pairs <- pairs[nzchar(pairs)]
  kv <- strsplit(pairs, "=", fixed = TRUE)
  caps <- as.integer(vapply(kv, `[`, character(1L), 2L))
  names(caps) <- vapply(kv, `[`, character(1L), 1L)
  caps
}

# Skip unless a real cluster is configured via the environment (nodes + project
# directory + dial-back host). Keeps the multi-node test dormant by default.
skip_if_no_ssh_cluster <- function() {
  needed <- c("CREW_SSH_TEST_NODES", "CREW_SSH_TEST_PROJDIR", "CREW_SSH_TEST_HOST")
  testthat::skip_if_not(
    all(nzchar(Sys.getenv(needed))),
    sprintf("set %s to run the multi-node SSH test", paste(needed, collapse = ", "))
  )
}
