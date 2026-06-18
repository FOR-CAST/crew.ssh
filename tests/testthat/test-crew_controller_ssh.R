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

test_that("crew_controller_ssh validates node input", {
  expect_snapshot(error = TRUE, crew_controller_ssh(nodes = c(2L), projdir = "/proj"))
})
