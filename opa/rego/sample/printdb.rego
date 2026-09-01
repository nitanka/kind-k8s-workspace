package printdb

db contains {"msg": msg, "result": result_id} if {
    some result_id in db_server

    msg := sprintf(
        "Server '%s' is using the insecure telnet protocol",
        [result_id.id]
    )
}

db_server contains result if {
    some server in input.servers

    some protocol in ["mysql", "memcache"]
    protocol in server.protocols
    some port_id in server.ports
    some port in input.ports
    port_id == port.id

    result := {
        "id": server.id,
        "port": port_id,
        "network": port.network
    }
}

# {
#   "servers": [
#     { "id": "app", "protocols": ["https", "ssh"], "ports": ["p1", "p2", "p3"] },
#     { "id": "db", "protocols": ["mysql"], "ports": ["p3"] },
#     { "id": "cache", "protocols": ["memcache"], "ports": ["p3"] },
#     { "id": "ci", "protocols": ["http"], "ports": ["p1", "p2"] },
#     { "id": "busybox", "protocols": ["telnet"], "ports": ["p1"] }
#   ],
#   "networks": [
#     { "id": "net1", "public": false },
#     { "id": "net2", "public": false },
#     { "id": "net3", "public": true }
#   ],
#   "ports": [
#     { "id": "p1", "network": "net1" },
#     { "id": "p2", "network": "net3" },
#     { "id": "p3", "network": "net2" }
#   ]
# }