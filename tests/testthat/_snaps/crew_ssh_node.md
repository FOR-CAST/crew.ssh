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

