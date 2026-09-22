# The bundled node-provisioning template (inst/templates) restores the default renv
# profile and then each profile in `crew.ssh.renv_profiles`. These tests run it
# with --dry-run in a scratch project. The dry run still runs the read-only ssh
# preflight, but the host is under .invalid, so it fails at name resolution and
# the script goes on to print the remote script it would run.

run_template_dry_run <- function(renv_profiles = NULL, profile_locks = character()) {
  template <- system.file("templates", "sync-nodes.R", package = "crew.ssh")
  dir <- tempfile("crew-ssh-template-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  hosts <- c(
    "options(",
    "  crew.ssh.nodes = c('unresolvable-host.invalid' = 1L),",
    "  crew.ssh.projdir = '/srv/project',",
    "  crew.ssh.branch = 'main',",
    "  crew.ssh.rscript = 'Rscript-9.9.9'",
    ")",
    if (!is.null(renv_profiles)) {
      sprintf("options(crew.ssh.renv_profiles = %s)", deparse(renv_profiles))
    }
  )
  writeLines(hosts, file.path(dir, "_hosts.R"))
  for (p in profile_locks) {
    dir.create(file.path(dir, "renv", "profiles", p), recursive = TRUE)
    writeLines("{}", file.path(dir, "renv", "profiles", p, "renv.lock"))
  }

  res <- processx::run(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", template, "--dry-run"),
    wd = dir,
    error_on_status = FALSE,
    stderr_to_stdout = TRUE,
    timeout = 120
  )
  ## right-trimmed: the script prints the remote script with cat(x, "\n"), which
  ## leaves a space before the final newline
  lines <- trimws(strsplit(res$stdout, "\n", fixed = TRUE)[[1]], which = "right")
  list(status = res$status, lines = lines)
}

default_restore <- "Rscript-9.9.9 -e 'renv::restore(prompt = FALSE)'"

test_that("each extra profile is restored after the default profile", {
  out <- run_template_dry_run(c("landr", "dev"), profile_locks = c("landr", "dev"))
  expect_identical(out$status, 0L)

  at <- function(line) match(line, out$lines)
  default <- at(default_restore)
  landr <- at("RENV_PROFILE=landr Rscript-9.9.9 -e 'renv::restore(prompt = FALSE)'")
  dev <- at("RENV_PROFILE=dev Rscript-9.9.9 -e 'renv::restore(prompt = FALSE)'")
  done <- at("echo '[done]'")

  expect_false(anyNA(c(default, landr, dev, done)))
  expect_true(default < landr && landr < dev && dev < done)
  expect_true(any(out$lines == "Extra renv profiles: landr, dev"))
})

test_that("without the option only the default profile is restored", {
  out <- run_template_dry_run()
  expect_identical(out$status, 0L)
  expect_true(default_restore %in% out$lines)
  expect_false(any(grepl("RENV_PROFILE", out$lines, fixed = TRUE)))
})

test_that("a profile name that is not a plain name stops before any node is contacted", {
  out <- run_template_dry_run("landr; rm -rf ~", profile_locks = character())
  expect_false(identical(out$status, 0L))
  expect_true(any(grepl("crew.ssh.renv_profiles must be profile names", out$lines, fixed = TRUE)))
  expect_false(any(grepl("preflight", out$lines, fixed = TRUE)))
})

test_that("renv's own 'default' profile name and path components are rejected", {
  for (bad in c("default", "..")) {
    out <- run_template_dry_run(bad, profile_locks = character())
    expect_false(identical(out$status, 0L))
    expect_true(any(grepl("other than 'default'", out$lines, fixed = TRUE)))
  }
})

test_that("a profile without a lockfile stops before any node is contacted", {
  out <- run_template_dry_run(c("landr", "typo"), profile_locks = "landr")
  expect_false(identical(out$status, 0L))
  expect_true(any(grepl("renv.lock for crew.ssh.renv_profiles: typo", out$lines, fixed = TRUE)))
  expect_false(any(grepl("preflight", out$lines, fixed = TRUE)))
})
