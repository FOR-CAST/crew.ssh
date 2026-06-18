test_that("crew_ssh_node builds a spec with defaults", {
  n <- crew_ssh_node("host1", 88)
  expect_s3_class(n, "crew_ssh_node")
  expect_identical(n$host, "host1")
  expect_identical(n$workers, 88L)
  expect_null(n$rscript)
  expect_null(n$projdir)
})

test_that("crew_ssh_node validates host and workers", {
  expect_snapshot(error = TRUE, crew_ssh_node("", 1))
  expect_snapshot(error = TRUE, crew_ssh_node("host1", 0))
  expect_snapshot(error = TRUE, crew_ssh_node("host1", "many"))
})

test_that("normalize_nodes expands a named vector and applies defaults", {
  nodes <- normalize_nodes(
    c(host1 = 45L, host2 = 88L),
    rscript = "/opt/R/4.6.0/bin/Rscript",
    projdir = "/proj",
    ssh_options = c("-o", "BatchMode=yes")
  )
  expect_named(nodes, c("host1", "host2"))
  expect_identical(nodes$host1$projdir, "/proj")
  expect_identical(nodes$host2$rscript, "/opt/R/4.6.0/bin/Rscript")
  expect_identical(vapply(nodes, function(n) n$workers, integer(1L)), c(host1 = 45L, host2 = 88L))
})

test_that("normalize_nodes resolves a NULL rscript via homogeneous", {
  hom <- normalize_nodes(
    c(a = 1L),
    rscript = NULL,
    projdir = "/p",
    ssh_options = NULL,
    homogeneous = TRUE
  )
  expect_identical(hom$a$rscript, file.path(R.home("bin"), "Rscript"))

  het <- normalize_nodes(
    c(a = 1L),
    rscript = NULL,
    projdir = "/p",
    ssh_options = NULL,
    homogeneous = FALSE
  )
  expect_identical(het$a$rscript, "Rscript")
})

test_that("normalize_nodes keeps per-node overrides", {
  nodes <- normalize_nodes(
    list(crew_ssh_node("a", 2L, rscript = "Rdev"), crew_ssh_node("b", 3L)),
    rscript = "Rscript",
    projdir = "/proj",
    ssh_options = NULL
  )
  expect_identical(nodes$a$rscript, "Rdev")
  expect_identical(nodes$b$rscript, "Rscript")
})

test_that("normalize_nodes errors on unnamed vector, missing projdir, dup hosts", {
  expect_snapshot(
    error = TRUE,
    normalize_nodes(c(45L), rscript = "R", projdir = "/p", ssh_options = NULL)
  )
  expect_snapshot(
    error = TRUE,
    normalize_nodes(c(a = 1L), rscript = "R", projdir = NULL, ssh_options = NULL)
  )
  expect_snapshot(
    error = TRUE,
    normalize_nodes(
      list(crew_ssh_node("a", 1L, projdir = "/p"), crew_ssh_node("a", 2L, projdir = "/p")),
      rscript = "R",
      projdir = "/p",
      ssh_options = NULL
    )
  )
})
