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


package count

p3_servers contains server.id if {
    some server in input.servers
    "p3" in server.ports
}

default allow := false

violations contains msg if {
    some server in p3_servers
    msg := sprintf("This server is violating %s", [server])
}

# allow if {
#     count(p3_servers) < 0
# }

allow if {
    count(violations) == 0
}