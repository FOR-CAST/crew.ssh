# Multi-node integration test against a REAL cluster, configured entirely via the
# environment (no hostnames are hard-coded). Dormant unless CREW_SSH_TEST_NODES /
# _PROJDIR / _HOST are set; see skip_if_no_ssh_cluster() and the setup vignette.

test_that("workers run tasks across multiple real nodes", {
  skip_on_cran()
  skip_if_no_ssh_cluster()

  nodes <- crew_ssh_test_nodes()
  rscript <- Sys.getenv("CREW_SSH_TEST_RSCRIPT")
  controller <- crew_controller_ssh(
    name = "cluster",
    nodes = nodes,
    projdir = Sys.getenv("CREW_SSH_TEST_PROJDIR"),
    host = Sys.getenv("CREW_SSH_TEST_HOST"),
    rscript = if (nzchar(rscript)) rscript else NULL,
    seconds_idle = 30
  )
  controller$start()
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)

  n_tasks <- 3L * sum(nodes)
  for (i in seq_len(n_tasks)) {
    controller$push(command = Sys.info()[["nodename"]], name = sprintf("t%03d", i))
  }
  controller$wait(seconds_timeout = 600)

  used <- character(0)
  repeat {
    task <- controller$pop()
    if (is.null(task)) {
      break
    }
    used <- c(used, task$result[[1]])
  }

  expect_length(used, n_tasks)
  expect_gt(length(unique(used)), 1L) # work actually spread across >1 node
})
