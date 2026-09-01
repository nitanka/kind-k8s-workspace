package k8sadmissioncontrol

default allow := false



allow if {
    count(violation) == 0
}

violation contains msg if {

    not "orgName" in input.metadata.labels
    msg := sprintf("Deployment : %s rule1", [input.metadata.name])
}

violation contains msg if {
    not "owner" in input.metadata.labels

    msg := sprintf("Deployment : %s rule2", [input.metadata.name])
}

violation contains msg if {
    not "costcenter" in input.metadata.labels

    msg := sprintf("Deployment : %s rule3", [input.metadata.name])
}
