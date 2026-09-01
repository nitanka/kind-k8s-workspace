package example

default allow := false                              # unless otherwise defined, allow is false

allow if {                                          # allow is true if...
    count(violation) == 0                           # there are zero violations.
}

violation contains server.id if {                   # a server is in the violation set if...
    some server in input.servers                    # it exists in the input.servers collection and...
    "telnet" in server.protocols                    # it contains the "telnet" protocol.
}

violation contains server.id if {
    some server in public_servers
    some protocol in server.protocols
    protocol in {"http", "ssh"}
}

public_servers contains server if {                  # a server exists in the 'public_servers' set if...
    some server in input.servers                    # it exists in the input.servers collection and...
    some port in server.ports                       # it references a port in the input.ports collection and...
    some input_port in input.ports
    port == input_port.id
    some input_network in input.networks            # the port references a network in the input.networks collection and...
    input_port.network == input_network.id          # the network is public.
    input_network.public
}