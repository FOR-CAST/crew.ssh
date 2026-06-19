## Live CPU / memory monitor for SSH worker nodes. The runtime sibling of
## crew_ssh_check(): instead of a one-shot preflight, poll each node on a timer
## and show CPU% and memory use side by side, so you do not need to open an htop
## per machine. Workers are assumed to be Linux (stats are read from /proc).

## Remote shell one-liner, run on each node. Samples /proc/stat twice to get a
## CPU% over a short interval, then reads memory and load. Prints one line:
##   "CPU MEMUSED_KB MEMTOTAL_KB LOAD1 NCPU"
## Passed as a single argument to ssh, so the remote login shell runs it (the
## single-quoted awk programs are evaluated remotely, not locally). Internal.
monitor_probe <- paste(
  "read -r _ u1 n1 s1 i1 w1 q1 sq1 _ < /proc/stat",
  "b1=$((u1+n1+s1+q1+sq1)); t1=$((u1+n1+s1+i1+w1+q1+sq1))",
  "sleep 0.25",
  "read -r _ u2 n2 s2 i2 w2 q2 sq2 _ < /proc/stat",
  "b2=$((u2+n2+s2+q2+sq2)); t2=$((u2+n2+s2+i2+w2+q2+sq2))",
  "db=$((b2-b1)); dt=$((t2-t1)); cpu=0",
  '[ "$dt" -gt 0 ] && cpu=$((100*db/dt))',
  "mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)",
  "ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)",
  "read -r l1 _ < /proc/loadavg",
  'echo "$cpu $((mt-ma)) $mt $l1 $(nproc)"',
  sep = "; "
)

## Default ssh options for the monitor: like the preflight defaults, but add
## connection multiplexing (ControlMaster) so repeated polls reuse one SSH
## connection per host instead of reconnecting every tick. %C is ssh's safe
## per-connection hash token, so the socket path needs no escaping. Internal.
monitor_default_ssh_options <- function() {
  c(
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "ControlMaster=auto",
    "-o",
    "ControlPersist=60s",
    "-o",
    paste0("ControlPath=", file.path(tempdir(), "crew-ssh-mon-%C"))
  )
}

## Build the ssh args that poll one node: c(<ssh options>, <host>, <probe>).
## Pure + testable, mirroring build_probe_args(). Internal.
build_monitor_args <- function(spec) {
  c(spec$ssh_options, spec$host, monitor_probe)
}

## Parse the probe's stdout ("CPU MEMUSED_KB MEMTOTAL_KB LOAD1 NCPU") into a
## one-node result list. Returns ok = FALSE on any malformed output. Pure +
## testable. Internal.
parse_monitor_line <- function(stdout, host) {
  fields <- strsplit(trimws(stdout), "\\s+")[[1]]
  v <- suppressWarnings(as.numeric(fields))
  if (length(v) < 5L || anyNA(v[1:3])) {
    return(list(host = host, ok = FALSE))
  }
  list(
    host = host,
    ok = TRUE,
    cpu = v[[1]],
    mem_used_kb = v[[2]],
    mem_total_kb = v[[3]],
    load1 = v[[4]],
    ncpu = v[[5]]
  )
}

## Poll a single node, never throwing (a failed/timed-out ssh becomes
## ok = FALSE). Internal.
monitor_poll_one <- function(spec, timeout) {
  res <- run_ssh(build_monitor_args(spec), timeout)
  if (!identical(res$status, 0L) || !nzchar(trimws(res$stdout))) {
    return(list(host = spec$host, ok = FALSE))
  }
  parse_monitor_line(res$stdout, spec$host)
}

## Map a function over node specs, in parallel where supported (one forked ssh
## per host, so a tick costs ~one round-trip rather than N). Internal.
poll_map <- function(specs, fun) {
  if (.Platform$OS.type != "windows" && length(specs) > 1L) {
    cores <- min(length(specs), max(1L, parallel::detectCores()))
    parallel::mclapply(specs, fun, mc.cores = cores)
  } else {
    lapply(specs, fun)
  }
}

## Poll all nodes once. Internal.
monitor_poll <- function(specs, timeout) {
  poll_map(specs, function(spec) monitor_poll_one(spec, timeout))
}

## Close any persistent SSH master connections opened by the monitor. Internal.
monitor_close_connections <- function(specs) {
  for (spec in specs) {
    try(run_ssh(c(spec$ssh_options, "-O", "exit", spec$host), timeout = 5), silent = TRUE)
  }
}

## A coloured horizontal bar (green/amber/red) with a right-aligned percent.
## Internal.
monitor_bar <- function(pct) {
  pct <- max(0, min(100, round(pct)))
  col <- if (pct >= 90) {
    "#d9534f"
  } else if (pct >= 60) {
    "#f0ad4e"
  } else {
    "#5cb85c"
  }
  htmltools::div(
    style = "display:flex;align-items:center;gap:8px;",
    htmltools::div(
      style = "flex:1;background:#e9e9e9;border-radius:3px;height:15px;min-width:90px;",
      htmltools::div(
        style = sprintf("width:%d%%;background:%s;height:100%%;border-radius:3px;", pct, col)
      )
    ),
    htmltools::span(
      style = "width:40px;text-align:right;font-variant-numeric:tabular-nums;",
      paste0(pct, "%")
    )
  )
}

## Render the poll results as an HTML table (one row per node). Internal.
monitor_render <- function(results) {
  th <- function(x, w = NULL) {
    htmltools::tags$th(
      x,
      style = paste0(
        "text-align:left;padding:4px 10px;border-bottom:1px solid #ccc;",
        if (!is.null(w)) sprintf("width:%s;", w) else ""
      )
    )
  }
  td <- function(...) htmltools::tags$td(..., style = "padding:5px 10px;vertical-align:middle;")

  rows <- lapply(results, function(r) {
    if (!isTRUE(r$ok)) {
      return(htmltools::tags$tr(
        td(htmltools::strong(r$host)),
        htmltools::tags$td("unreachable", colspan = "4", style = "padding:5px 10px;color:#d9534f;")
      ))
    }
    gu <- round(r$mem_used_kb / 1048576)
    gt <- round(r$mem_total_kb / 1048576)
    mempct <- if (r$mem_total_kb > 0) 100 * r$mem_used_kb / r$mem_total_kb else 0
    htmltools::tags$tr(
      td(htmltools::strong(r$host)),
      td(monitor_bar(r$cpu)),
      td(monitor_bar(mempct)),
      td(htmltools::span(
        sprintf("%d / %d GiB", gu, gt),
        style = "font-variant-numeric:tabular-nums;"
      )),
      td(htmltools::span(
        sprintf("%.2f / %d", r$load1, as.integer(r$ncpu)),
        style = "font-variant-numeric:tabular-nums;color:#555;"
      ))
    )
  })

  htmltools::tagList(
    htmltools::div(
      style = "color:#888;font-size:12px;margin-bottom:6px;",
      paste("updated", format(Sys.time(), "%H:%M:%S"))
    ),
    htmltools::tags$table(
      style = "width:100%;border-collapse:collapse;font-family:monospace;font-size:13px;",
      htmltools::tags$thead(htmltools::tags$tr(
        th("HOST", "110px"),
        th("CPU"),
        th("RAM"),
        th("MEM USED", "120px"),
        th("LOAD / CORES", "120px")
      )),
      htmltools::tags$tbody(rows)
    )
  )
}

#' Live CPU and memory monitor for SSH worker nodes
#'
#' \strong{Experimental.} Open a small dashboard that polls each node over SSH on
#' a timer and shows CPU and memory use, one row per machine, in a single window.
#' It is the runtime companion to [crew_ssh_check()]: where the preflight is a
#' one-shot diagnostic, this keeps refreshing so you can watch a running cluster
#' without opening a terminal and `htop` per node. The dashboard is a
#' \pkg{miniUI} gadget and renders in the RStudio / VS Code Viewer pane (the same
#' place `targets::tar_visnetwork()` appears), so you can alt-tab to it.
#'
#' Worker stats are read directly from `/proc` (`/proc/stat`, `/proc/meminfo`,
#' `/proc/loadavg`), so the **nodes must run Linux**; nothing beyond a POSIX
#' shell is required on them. Nodes are polled in parallel, and connections are
#' multiplexed (`ControlMaster`) so each refresh reuses one SSH connection per
#' host.
#'
#' Requires the \pkg{shiny}, \pkg{miniUI}, and \pkg{htmltools} packages (in
#' `Suggests`); install them to use this function.
#'
#' @inheritParams crew_controller_ssh
#' @param interval Refresh interval in seconds (default `2`).
#' @param timeout Per-poll SSH timeout in seconds (default `10`).
#' @param viewer A \pkg{shiny} viewer function controlling where the gadget
#'   opens. `NULL` (the default) uses [shiny::paneViewer()] (the Viewer pane);
#'   pass [shiny::browserViewer()] to open in a web browser instead.
#'
#' @return Invisibly, the gadget's return value (`NULL`); called for its side
#'   effect of opening the dashboard.
#' @family ssh
#' @export
#' @examples
#' \dontrun{
#' # monitor the same nodes used by the controller / preflight
#' crew_ssh_monitor(nodes = c(host1 = 1L, host2 = 1L))
#'
#' # in a project that sets the crew.ssh.nodes option
#' crew_ssh_monitor(getOption("crew.ssh.nodes"))
#' }
crew_ssh_monitor <- function(
  nodes,
  interval = 2,
  rscript = NULL,
  homogeneous = TRUE,
  ssh_options = NULL,
  timeout = 10,
  viewer = NULL
) {
  if (is.null(ssh_options)) {
    ssh_options <- monitor_default_ssh_options()
  }
  specs <- normalize_nodes(
    nodes,
    rscript = rscript,
    projdir = NULL,
    ssh_options = ssh_options,
    homogeneous = homogeneous
  )

  for (pkg in c("shiny", "miniUI", "htmltools")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop(
        "`crew_ssh_monitor()` requires the '",
        pkg,
        "' package. Install it with install.packages(\"",
        pkg,
        "\").",
        call. = FALSE
      )
    }
  }

  if (is.null(viewer)) {
    viewer <- shiny::paneViewer()
  }

  ui <- miniUI::miniPage(
    miniUI::gadgetTitleBar(
      sprintf("crew.ssh monitor  (%d node(s), every %ss)", length(specs), interval),
      right = miniUI::miniTitleBarButton("done", "Close", primary = TRUE)
    ),
    miniUI::miniContentPanel(shiny::uiOutput("tbl"))
  )

  server <- function(input, output, session) {
    tick <- shiny::reactiveTimer(interval * 1000)
    output$tbl <- shiny::renderUI({
      tick()
      monitor_render(monitor_poll(specs, timeout))
    })
    shiny::observeEvent(input$done, shiny::stopApp())
    session$onSessionEnded(function() monitor_close_connections(specs))
  }

  invisible(shiny::runGadget(ui, server, viewer = viewer))
}
