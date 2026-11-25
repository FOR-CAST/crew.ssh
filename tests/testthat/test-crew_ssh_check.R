test_that("build_probe_args appends packages as trailing args (no --args)", {
  spec <- crew_ssh_node(
    "a",
    1L,
    rscript = "Rscript",
    projdir = "/p",
    ssh_options = c("-o", "BatchMode=yes")
  )
  args <- build_probe_args(spec, packages = c("crew", "foo"))
  expect_identical(args[1:3], c("-o", "BatchMode=yes", "a"))
  expect_match(args[[4]], "^cd '/p' && 'Rscript' -e '.*' crew foo$")
  expect_no_match(args[[4]], "--args") # Rscript supplies its own
})

test_that("build_probe_args omits packages when none given", {
  spec <- crew_ssh_node("a", 1L, rscript = "Rscript", projdir = "/p", ssh_options = NULL)
  args <- build_probe_args(spec)
  expect_match(args[[length(args)]], "^cd '/p' && 'Rscript' -e '.*'$")
})

test_that("build_probe_args starts the probe the way a worker starts", {
  spec <- crew_ssh_node(
    "a",
    1L,
    rscript = "Rscript",
    projdir = "/p",
    slice = "crew.slice",
    memory_max = "50%"
  )
  remote <- build_probe_args(spec, packages = "crew")[[2]]
  expect_identical(sub(" -e .*$", "", remote), sub(" -e .*$", "", build_ssh_args(spec, "f()")[[2]]))
  expect_match(remote, " crew$")
})

test_that("the probe reports R's version, its memory limit and the packages", {
  skip_on_os("windows")
  result <- processx::run(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", "-e", ssh_probe_expr, "stats", "notapackage.crewssh")
  )
  out <- strsplit(result$stdout, "\n", fixed = TRUE)[[1]]
  expect_true(any(grepl("^R_VERSION=[0-9]", out)))
  ## a number of bytes, Inf where no cgroup limit is set, NA where cgroups cannot be read
  expect_match(grep("^MEMORY_MAX=", out, value = TRUE), "^MEMORY_MAX=([0-9]+|Inf|NA)$")
  expect_true("PKG=stats=TRUE" %in% out)
  expect_true("PKG=notapackage.crewssh=FALSE" %in% out)
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
