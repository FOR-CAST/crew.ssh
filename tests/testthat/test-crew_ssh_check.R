test_that("build_probe_args builds the remote probe command", {
  spec <- crew_ssh_node(
    "a",
    1L,
    rscript = "Rscript",
    projdir = "/p",
    ssh_options = c("-o", "BatchMode=yes")
  )
  args <- build_probe_args(spec, packages = c("crew", "foo"))
  expect_identical(args[1:3], c("-o", "BatchMode=yes", "a"))
  expect_match(args[[4]], "^cd '/p' && 'Rscript' -e '.*' --args crew foo$")
})

test_that("build_probe_args omits --args when no packages", {
  spec <- crew_ssh_node("a", 1L, rscript = "Rscript", projdir = "/p", ssh_options = NULL)
  args <- build_probe_args(spec)
  expect_no_match(args[[length(args)]], "--args")
})

test_that("crew_ssh_check reports OK for a reachable localhost", {
  skip_on_cran()
  skip_if_no_local_ssh()

  projdir <- tempfile("crew_ssh_chk_")
  dir.create(projdir)
  on.exit(unlink(projdir, recursive = TRUE), add = TRUE)
  libs <- paste0('c("', paste(.libPaths(), collapse = '", "'), '")')
  writeLines(sprintf(".libPaths(%s)", libs), file.path(projdir, ".Rprofile"))

  res <- crew_ssh_check(nodes = c(localhost = 1L), projdir = projdir, packages = "crew")
  expect_s3_class(res, "crew_ssh_check")
  expect_true(res$ssh[[1]])
  expect_true(res$projdir[[1]])
  expect_true(res$ok[[1]])
})
