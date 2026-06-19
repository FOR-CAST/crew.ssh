test_that("build_monitor_args is ssh options, host, then the probe", {
  spec <- crew_ssh_node("a", 1L, projdir = NULL, ssh_options = c("-o", "BatchMode=yes"))
  args <- build_monitor_args(spec)
  expect_identical(args[1:3], c("-o", "BatchMode=yes", "a"))
  expect_identical(args[[4]], monitor_probe)
})

test_that("monitor_probe reads /proc and prints five fields", {
  expect_match(monitor_probe, "/proc/stat")
  expect_match(monitor_probe, "/proc/meminfo")
  expect_match(monitor_probe, "/proc/loadavg")
  expect_match(monitor_probe, "nproc")
})

test_that("parse_monitor_line parses a well-formed line", {
  r <- parse_monitor_line("37 5574348 528242988 1.58 64", "host1")
  expect_true(r$ok)
  expect_identical(r$host, "host1")
  expect_identical(r$cpu, 37)
  expect_identical(r$mem_used_kb, 5574348)
  expect_identical(r$mem_total_kb, 528242988)
  expect_identical(r$load1, 1.58)
  expect_identical(r$ncpu, 64)
})

test_that("parse_monitor_line tolerates surrounding whitespace", {
  r <- parse_monitor_line("  10 1 2 0.5 8\n", "h")
  expect_true(r$ok)
  expect_identical(r$cpu, 10)
})

test_that("parse_monitor_line flags malformed or empty output as not ok", {
  expect_false(parse_monitor_line("", "h")$ok)
  expect_false(parse_monitor_line("garbage", "h")$ok)
  expect_false(parse_monitor_line("1 2 3", "h")$ok)
  expect_false(parse_monitor_line("x y z 0.1 4", "h")$ok)
})

test_that("crew_ssh_monitor validates nodes before opening a gadget", {
  expect_snapshot(error = TRUE, crew_ssh_monitor(nodes = c(1L, 2L)))
})
