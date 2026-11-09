## The tests use at most 2 cores, as CRAN asks. OpenMP and BLAS read their limits when R starts, so
## this R keeps the ones it started with (the GitHub workflows set them); the R processes the tests
## start get them from here.
withr::local_envvar(
  OMP_THREAD_LIMIT = "2",
  OMP_NUM_THREADS = "2",
  OPENBLAS_NUM_THREADS = "2",
  MKL_NUM_THREADS = "2",
  .local_envir = testthat::teardown_env()
)
