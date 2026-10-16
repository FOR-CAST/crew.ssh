test_that("build_ssh_args constructs the remote ssh command", {
  spec <- crew_ssh_node(
    "host1",
    1L,
    rscript = "Rscript",
    projdir = "/proj",
    ssh_options = c("-o", "BatchMode=yes")
  )
  args <- build_ssh_args(spec, call = "crew::crew_worker(x)")
  expect_identical(args[1:3], c("-o", "BatchMode=yes", "host1"))
  expect_length(args, 4L)
  expect_identical(args[[4]], "cd '/proj' && 'Rscript' -e 'crew::crew_worker(x)'")
})

test_that("build_ssh_args interleaves r_arguments and omits options when NULL", {
  spec <- crew_ssh_node("a", 1L, rscript = "Rscript", projdir = "/p", ssh_options = NULL)
  args <- build_ssh_args(spec, "f()", r_arguments = c("--vanilla", "--no-echo"))
  expect_identical(args[[1]], "a")
  expect_identical(args[[2]], "cd '/p' && 'Rscript' --vanilla --no-echo -e 'f()'")
})

test_that("build_ssh_args prepends -tt only when request_tty = TRUE", {
  spec <- crew_ssh_node(
    "host1",
    1L,
    rscript = "Rscript",
    projdir = "/p",
    ssh_options = c("-o", "BatchMode=yes")
  )
  expect_identical(
    build_ssh_args(spec, "f()", request_tty = TRUE)[1:4],
    c("-tt", "-o", "BatchMode=yes", "host1")
  )
  expect_false("-tt" %in% build_ssh_args(spec, "f()"))
})

test_that("dispatcher_port extracts the port from a crew_worker url", {
  call <- 'crew::crew_worker(settings = list(url = "tcp://127.0.0.1:57231", x = 1))'
  expect_identical(dispatcher_port(call), 57231L)
  expect_identical(dispatcher_port('list(url = "tcp://localhost:5000")'), 5000L)
  expect_true(is.na(dispatcher_port("no url here")))
})

test_that("rewrite_url_port repoints only the dispatcher port", {
  expect_identical(
    rewrite_url_port('url = "tcp://127.0.0.1:57231"', 57231L, 49152L),
    'url = "tcp://127.0.0.1:49152"'
  )
  ## a like-numbered token elsewhere is left untouched
  expect_identical(
    rewrite_url_port('x = 57231; "tcp://127.0.0.1:57231"', 57231L, 49152L),
    'x = 57231; "tcp://127.0.0.1:49152"'
  )
})

test_that("build_ssh_args adds the reverse-tunnel forward when requested", {
  spec <- crew_ssh_node(
    "host1",
    1L,
    rscript = "Rscript",
    projdir = "/p",
    ssh_options = c("-o", "BatchMode=yes")
  )
  args <- build_ssh_args(spec, "f()", tunnel = "49152:127.0.0.1:55000")
  expect_identical(args[1:4], c("-R", "49152:127.0.0.1:55000", "-o", "ExitOnForwardFailure=yes"))
  expect_false("-R" %in% build_ssh_args(spec, "f()"))
})

test_that("weighted_pick distributes launches in proportion to caps", {
  caps <- c(small = 1L, big = 3L)
  assigned <- caps * 0L
  picks <- character(sum(caps))
  for (i in seq_len(sum(caps))) {
    index <- weighted_pick(assigned, caps)
    host <- names(caps)[index]
    picks[i] <- host
    assigned[host] <- assigned[host] + 1L
  }
  expect_identical(as.integer(table(factor(picks, levels = names(caps)))), c(1L, 3L))
})

test_that("the launcher subclasses crew_class_launcher", {
  controller <- crew_controller_ssh(
    nodes = c(a = 1L, b = 3L),
    projdir = "/proj",
    host = "127.0.0.1"
  )
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)
  expect_s3_class(controller$launcher, "crew_class_launcher_ssh")
  expect_s3_class(controller$launcher, "crew_class_launcher")
})

## Worker stdout/stderr is the only record of why a worker died: the ssh client
## forwards the remote R's output, and ssh's own "Timeout, server not
## responding" goes to the same stream. Discarding it makes a lost worker
## undiagnosable, which is what happened before these tests existed.
ssh_controller <- function(...) {
  crew_controller_ssh(nodes = c(a = 1L), projdir = "/proj", host = "127.0.0.1", ...)
}

test_that("log paths are NULL when no log directory is configured", {
  controller <- ssh_controller()
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)
  private <- controller$launcher$.__enclos_env__$private
  expect_null(private$.log_path("stdout", "worker1"))
  expect_null(private$.log_path("stderr", "worker1"))
})

test_that("log paths are per-worker files under the configured directory", {
  dir <- tempfile("crew_ssh_logs_")
  joined <- ssh_controller(log_directory = dir)
  on.exit(try(joined$terminate(), silent = TRUE), add = TRUE)
  private <- joined$launcher$.__enclos_env__$private
  expect_identical(private$.log_path("stdout", "w1"), file.path(dir, "w1.log"))
  ## joined by default, so stderr is merged into the stdout file
  expect_identical(private$.log_path("stderr", "w1"), "2>&1")

  split <- ssh_controller(log_directory = dir, log_join = FALSE)
  on.exit(try(split$terminate(), silent = TRUE), add = TRUE)
  private_split <- split$launcher$.__enclos_env__$private
  expect_identical(private_split$.log_path("stdout", "w1"), file.path(dir, "w1-stdout.log"))
  expect_identical(private_split$.log_path("stderr", "w1"), file.path(dir, "w1-stderr.log"))
})

test_that("log_prepare creates the log directory", {
  root <- tempfile("crew_ssh_logs_")
  dir <- file.path(root, "nested")
  controller <- ssh_controller(log_directory = dir)
  on.exit(
    {
      try(controller$terminate(), silent = TRUE)
      unlink(root, recursive = TRUE)
    },
    add = TRUE
  )
  expect_false(dir.exists(dir))
  controller$launcher$.__enclos_env__$private$.log_prepare()
  expect_true(dir.exists(dir))
})

## crew drops its launch records, and with them the handles launch_worker() returns, once later
## workers connect. A collected handle killed its ssh client (`cleanup = TRUE`), and with it the
## worker's connection and reverse tunnel, mid-task.
fake_ssh <- function(script) {
  bin <- tempfile("crew_ssh_bin_")
  dir.create(bin)
  writeLines(c("#!/bin/sh", script), file.path(bin, "ssh"))
  Sys.chmod(file.path(bin, "ssh"), "0755")
  bin
}

test_that("a worker's ssh client survives garbage collection of crew's handle", {
  skip_on_os("windows")
  beat <- tempfile("crew_ssh_beat_")
  bin <- fake_ssh('i=0; while :; do i=$((i+1)); echo $i > "$CREW_SSH_TEST_BEAT"; sleep 0.1; done')
  path <- Sys.getenv("PATH")
  Sys.setenv(PATH = paste(bin, path, sep = .Platform$path.sep), CREW_SSH_TEST_BEAT = beat)
  controller <- ssh_controller()
  private <- controller$launcher$.__enclos_env__$private
  on.exit(
    {
      for (handle in private$.handles) {
        try(handle$kill(), silent = TRUE)
      }
      try(controller$terminate(), silent = TRUE)
      Sys.setenv(PATH = path)
      Sys.unsetenv("CREW_SSH_TEST_BEAT")
      unlink(c(bin, beat), recursive = TRUE)
    },
    add = TRUE
  )
  controller$launcher$launch_worker(call = "crew::crew_worker()")
  Sys.sleep(0.5)
  invisible(gc(full = TRUE))
  Sys.sleep(0.5)
  first <- as.integer(readLines(beat))
  Sys.sleep(0.5)
  expect_gt(as.integer(readLines(beat)), first)
})

test_that("the launcher drops exited ssh clients and releases the rest on terminate", {
  skip_on_os("windows")
  bin <- fake_ssh("exit 0")
  path <- Sys.getenv("PATH")
  Sys.setenv(PATH = paste(bin, path, sep = .Platform$path.sep))
  controller <- ssh_controller()
  private <- controller$launcher$.__enclos_env__$private
  on.exit(
    {
      try(controller$terminate(), silent = TRUE)
      Sys.setenv(PATH = path)
      unlink(bin, recursive = TRUE)
    },
    add = TRUE
  )
  first <- controller$launcher$launch_worker(call = "crew::crew_worker()")
  first$wait(5000)
  controller$launcher$launch_worker(call = "crew::crew_worker()")
  expect_length(private$.handles, 1L)
  controller$launcher$terminate()
  expect_length(private$.handles, 0L)
})

## Placement by cumulative launches let a node exceed its cap once workers were replaced (after a
## crash, or with tasks_max): a node whose workers finished sooner kept getting its share.
test_that("each launch goes to the node with the lowest share of live workers", {
  skip_on_os("windows")
  bin <- fake_ssh("sleep 60")
  path <- Sys.getenv("PATH")
  Sys.setenv(PATH = paste(bin, path, sep = .Platform$path.sep))
  controller <- crew_controller_ssh(
    nodes = c(a = 1L, b = 3L),
    projdir = "/proj",
    host = "127.0.0.1"
  )
  private <- controller$launcher$.__enclos_env__$private
  on.exit(
    {
      for (handle in private$.handles) {
        try(handle$kill(), silent = TRUE)
      }
      try(controller$terminate(), silent = TRUE)
      Sys.setenv(PATH = path)
      unlink(bin, recursive = TRUE)
    },
    add = TRUE
  )
  ## the host is the ssh client's second-to-last argument (the last is the remote command)
  host_of <- function(handle) {
    args <- handle$get_cmdline()
    args[length(args) - 1L]
  }
  live <- function() {
    running <- Filter(function(h) h$is_alive(), private$.handles)
    hosts <- vapply(running, host_of, character(1L))
    as.integer(table(factor(hosts, levels = c("a", "b"))))
  }
  for (i in 1:4) {
    controller$launcher$launch_worker(call = "crew::crew_worker()")
  }
  expect_identical(live(), c(1L, 3L))
  ## a worker on b exits: the next launch refills b, although a has had fewer launches
  exited <- Filter(function(h) host_of(h) == "b", private$.handles)[[1L]]
  exited$kill()
  exited$wait(5000)
  controller$launcher$launch_worker(call = "crew::crew_worker()")
  expect_identical(live(), c(1L, 3L))
})
