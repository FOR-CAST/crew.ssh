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

test_that("the launcher subclasses crew_class_launcher and places by capacity", {
  controller <- crew_controller_ssh(
    nodes = c(a = 1L, b = 3L),
    projdir = "/proj",
    host = "127.0.0.1"
  )
  on.exit(try(controller$terminate(), silent = TRUE), add = TRUE)
  launcher <- controller$launcher
  expect_s3_class(launcher, "crew_class_launcher_ssh")
  expect_s3_class(launcher, "crew_class_launcher")

  pick_node <- launcher$.__enclos_env__$private$.pick_node
  picks <- vapply(seq_len(4L), function(i) pick_node(), character(1L))
  expect_identical(sort(picks), c("a", "b", "b", "b"))
})
