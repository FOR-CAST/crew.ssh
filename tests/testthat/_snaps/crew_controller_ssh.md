# crew_controller_ssh validates node input

    Code
      crew_controller_ssh(nodes = c(2L), projdir = "/proj")
    Condition
      Error:
      ! When `nodes` is a numeric vector it must be fully named (host = capacity), e.g. c(node1 = 8L, node2 = 16L).

