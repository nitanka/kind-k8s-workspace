package k8sadmissioncontrol

# Return every container using an nginx image.
deployment_violations(deployment) := results if {
    results := [result |
        some container in deployment.spec.template.spec.containers

        result := {
            "deployment": deployment.metadata.name,
            "container": container.name,
            "image": container.image
        }
    ]
}