test_that("the tests use at most 2 cores", {
  expect_identical(Sys.getenv("OMP_THREAD_LIMIT"), "2")
})
