# crew_ssh_node validates host and workers

    Code
      crew_ssh_node("", 1)
    Condition
      Error:
      ! `host` must be a single non-empty string.

---

    Code
      crew_ssh_node("host1", 0)
    Condition
      Error:
      ! `workers` must be a single positive integer.

---

    Code
      crew_ssh_node("host1", "many")
    Condition
      Error:
      ! `workers` must be a single positive integer.

# normalize_nodes errors on unnamed vector and duplicate hosts

    Code
      normalize_nodes(c(45L), rscript = "R", projdir = "/p", ssh_options = NULL)
    Condition
      Error:
      ! When `nodes` is a numeric vector it must be fully named (host = capacity), e.g. c(node1 = 8L, node2 = 16L).

---

    Code
      normalize_nodes(list(crew_ssh_node("a", 1L, projdir = "/p"), crew_ssh_node("a",
        2L, projdir = "/p")), rscript = "R", projdir = "/p", ssh_options = NULL)
    Condition
      Error:
      ! Duplicate host(s) in `nodes`: a.

# normalize_nodes errors on an empty-string projdir

    Code
      normalize_nodes(c(a = 1L), rscript = "R", projdir = "", ssh_options = NULL)
    Condition
      Error:
      ! `projdir` must be supplied (per node or via the controller) as a single non-empty string.

# crew_ssh_node validates the slice and memory limit

    Code
      crew_ssh_node("host1", 1L, slice = "crew")
    Condition
      Error:
      ! `slice` must be a single systemd slice name ending in ".slice", e.g. "crew.slice".

---

    Code
      crew_ssh_node("host1", 1L, slice = "crew.slice; rm")
    Condition
      Error:
      ! `slice` must be a single systemd slice name ending in ".slice", e.g. "crew.slice".

---

    Code
      crew_ssh_node("host1", 1L, memory_max = "half")
    Condition
      Error:
      ! `memory_max` must be a single systemd memory limit: a size in bytes with an optional K, M, G, T, P or E suffix ("488G"), a percentage of the node's RAM ("50%"), or "infinity".

---

    Code
      crew_ssh_node("host1", 1L, memory_max = 0.5)
    Condition
      Error:
      ! `memory_max` must be a single systemd memory limit: a size in bytes with an optional K, M, G, T, P or E suffix ("488G"), a percentage of the node's RAM ("50%"), or "infinity".

# normalize_nodes refuses a memory limit without a slice

    Code
      normalize_nodes(c(a = 1L), rscript = "R", projdir = "/p", ssh_options = NULL,
      memory_max = "50%")
    Condition
      Error:
      ! `memory_max` needs a `slice` (node a): the limit is set on the systemd slice that holds the node's workers.

---

    Code
      normalize_nodes(c(a = 1L), rscript = "R", projdir = "/p", ssh_options = NULL,
      slice = "x")
    Condition
      Error:
      ! `slice` must be a single systemd slice name ending in ".slice", e.g. "crew.slice".

