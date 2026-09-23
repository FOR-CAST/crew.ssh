test_that("crew_controller_ssh builds a controller and propagates caps", {
  controller <- crew_controller_ssh(
    nodes = c(a = 2L, b = 3L),
    projdir = "/proj",
    host = "127.0.0.1"
  )
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)
  expect_s3_class(controller, "crew_class_controller")
  expect_identical(controller$launcher$caps, c(a = 2L, b = 3L))
  expect_identical(sum(controller$launcher$caps), 5L)
  expect_named(controller$launcher$nodes, c("a", "b"))
})

test_that("request_tty propagates to the launcher", {
  controller <- crew_controller_ssh(
    nodes = c(a = 1L),
    projdir = "/proj",
    host = "127.0.0.1",
    request_tty = TRUE
  )
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)
  expect_true(controller$launcher$request_tty)
})

test_that("tunnel = TRUE sets the launcher flag (dispatcher forced to localhost)", {
  controller <- suppressMessages(crew_controller_ssh(
    nodes = c(a = 1L),
    projdir = "/proj",
    tunnel = TRUE
  ))
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)
  expect_true(controller$launcher$tunnel)
})

test_that("crew_controller_ssh validates node input", {
  expect_snapshot(error = TRUE, crew_controller_ssh(nodes = c(2L), projdir = "/proj"))
})

test_that("the default ssh options tolerate a multi-minute stall", {
  opts <- eval(formals(crew_controller_ssh)$ssh_options)
  value <- function(key) {
    hit <- grep(paste0("^", key, "="), opts, value = TRUE)
    as.numeric(sub(".*=", "", hit))
  }
  interval <- value("ServerAliveInterval")
  count <- value("ServerAliveCountMax")
  expect_length(interval, 1L)
  expect_length(count, 1L)
  ## A worker whose ssh client gives up loses its tunnel, and mirai's autoexit
  ## then terminates the worker, so its target restarts from scratch. Both
  ## options must be set: OpenSSH's default count of 3 means a 90-second stall
  ## destroys every worker on every node at once.
  expect_gte(interval * count, 300)
})

test_that("log_directory and log_join propagate to the launcher", {
  dir <- tempfile("crew_ssh_logs_")
  controller <- crew_controller_ssh(
    nodes = c(a = 1L),
    projdir = "/proj",
    host = "127.0.0.1",
    log_directory = dir,
    log_join = FALSE
  )
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)
  expect_identical(controller$launcher$log_directory, dir)
  expect_false(controller$launcher$log_join)
})
