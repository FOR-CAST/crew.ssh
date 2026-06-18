# End-to-end test of the real launch path over a loopback SSH hop to localhost:
# launcher builds the command -> ssh starts a remote R -> crew_worker dials back
# -> runs a task -> returns the result. Opt-in (see skip_if_no_local_ssh()).

test_that("a worker runs a task over ssh to localhost", {
  skip_on_cran()
  skip_if_no_local_ssh()

  # The worker's R must find `crew`; point it at a projdir whose .Rprofile
  # restores the current library paths (mirrors how a real project's renv would).
  projdir <- tempfile("crew_ssh_proj_")
  dir.create(projdir)
  on.exit(unlink(projdir, recursive = TRUE), add = TRUE)
  libs <- paste0('c("', paste(.libPaths(), collapse = '", "'), '")')
  writeLines(sprintf(".libPaths(%s)", libs), file.path(projdir, ".Rprofile"))

  controller <- crew_controller_ssh(
    nodes = c(localhost = 1L),
    projdir = projdir,
    host = "127.0.0.1",
    seconds_idle = 5
  )
  controller$start()
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)

  controller$push(command = 1L + 1L, name = "probe")
  controller$wait(seconds_timeout = 90)
  out <- controller$pop()

  expect_false(is.null(out))
  expect_identical(out$result[[1]], 2L)
})
