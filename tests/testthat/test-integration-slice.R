## Opt-in (CREW_SSH_TEST_SLICE): starts two workers in a throwaway systemd user slice on this
## machine, through a stand-in `ssh` that runs the remote command here, and checks that they share
## the slice, that the slice carries the limit, and that R inside it sees the limit. Needs a
## systemd user manager with the memory controller delegated. Stops the slice and removes its
## runtime drop-in afterwards.
test_that("workers started with a slice share it, under its memory limit", {
  skip_on_cran()
  skip_on_os(c("windows", "mac"))
  skip_if_not(
    nzchar(Sys.getenv("CREW_SSH_TEST_SLICE")),
    "set CREW_SSH_TEST_SLICE to run the systemd slice test"
  )
  delegated <- processx::run("sh", c("-c", memory_delegated_command), error_on_status = FALSE)
  skip_if_not(
    identical(delegated$status, 0L),
    "the systemd user manager does not have the memory controller"
  )

  ## no "-" in the name: systemd would nest the slice under a parent
  slice <- paste0("crewsshtest_", crew::crew_random_name(), ".slice")
  systemctl <- function(...) {
    processx::run("systemctl", c("--user", ...), error_on_status = FALSE)
  }
  projdir <- tempfile("crew_ssh_slice_")
  dir.create(projdir)
  probe_out <- file.path(projdir, "probe.txt")
  bin <- fake_ssh('for last; do :; done; exec sh -c "$last"')
  path <- Sys.getenv("PATH")
  Sys.setenv(PATH = paste(bin, path, sep = .Platform$path.sep))
  controller <- crew_controller_ssh(
    nodes = list(crew_ssh_node("node", 2L, slice = slice, memory_max = "1G")),
    projdir = projdir,
    host = "127.0.0.1",
    r_arguments = "--vanilla"
  )
  private <- controller$launcher$.__enclos_env__$private
  on.exit(
    {
      systemctl("stop", slice)
      systemctl("revert", slice)
      for (handle in private$.handles) {
        try(handle$kill(), silent = TRUE)
      }
      try(controller$terminate(), silent = TRUE)
      Sys.setenv(PATH = path)
      unlink(c(bin, projdir), recursive = TRUE)
    },
    add = TRUE
  )

  ## one worker records what R sees of its cgroup limits, both then wait to be stopped
  probe <- sprintf("sink(%s); %s; sink()", deparse(probe_out), ssh_probe_expr)
  controller$launcher$launch_worker(call = paste0(probe, "; Sys.sleep(300)"))
  controller$launcher$launch_worker(call = "Sys.sleep(300)")

  cgroup <- trimws(systemctl("show", "-p", "ControlGroup", "--value", slice)$stdout)
  dir <- paste0("/sys/fs/cgroup", cgroup)
  scopes <- character()
  deadline <- Sys.time() + 30
  while (Sys.time() < deadline) {
    scopes <- list.files(dir, pattern = "[.]scope$", full.names = TRUE)
    procs <- unlist(lapply(file.path(scopes, "cgroup.procs"), readLines))
    if (length(procs) >= 2L && file.exists(probe_out) && length(readLines(probe_out))) {
      break
    }
    Sys.sleep(0.5)
  }
  expect_true(nzchar(cgroup))
  ## one scope per worker, each holding its R process
  expect_length(scopes, 2L)
  for (scope in scopes) {
    pids <- readLines(file.path(scope, "cgroup.procs"))
    expect_length(pids, 1L)
    expect_match(readLines(file.path("/proc", pids, "comm")), "^R$")
  }
  expect_identical(readLines(file.path(dir, "memory.max")), as.character(1024^3))
  expect_identical(readLines(file.path(dir, "memory.swap.max")), "0")
  expect_true(paste0("MEMORY_MAX=", 1024^3) %in% readLines(probe_out))

  ## stopping the slice ends its workers; reverting it removes the runtime drop-in
  systemctl("stop", slice)
  expect_false(any(dir.exists(scopes)))
  systemctl("revert", slice)
  dropin <- file.path(Sys.getenv("XDG_RUNTIME_DIR"), "systemd", "user.control", paste0(slice, ".d"))
  expect_false(dir.exists(dropin))
})
