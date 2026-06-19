# crew_ssh_monitor validates nodes before opening a gadget

    Code
      crew_ssh_monitor(nodes = c(1L, 2L))
    Condition
      Error:
      ! When `nodes` is a numeric vector it must be fully named (host = capacity), e.g. c(node1 = 8L, node2 = 16L).

