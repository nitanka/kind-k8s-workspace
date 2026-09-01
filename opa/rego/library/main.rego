package main

import data.k8sadmissioncontrol.deployment_violations

violations contains msg if {
    some result in deployment_violations(input)

    contains(result.image, "nginx")

    msg := sprintf(
        "Deployment '%s': Container '%s' is using nginx image '%s'",
        [
            result.deployment,
            result.container,
            result.image
        ]
    )
}

default allow := false

allow if {
    count(violations) == 0
}