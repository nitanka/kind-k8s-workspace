The following document is according my understanding of the SPIFFE and its implmentation:

## Overview

1. SPIFFE - Secure Production Identity Framework For Everyone 
2. It is a framework for managing identity of services or workload.
3. The identity is based on certificates, where each workload will have its own certificate.
4. SVID - SPIFFE verification identity document.
5. The SVID is a document reference, or how the certification will be implemented. It is not an ID.
6. SPIFFE supports k8s, virtual manchines and bare metal setup.


## Concepts

1. Applications will get their own certificate from the certificate authority.
2. The SAN of the certificate will have URI instead of DNS
3. Single certificate will have a single URI, cannot have more then one URI.
4. The server can also use upstream CA server to create certificates.

## Spire

1. Spire manages the certificate and have the CA certificate and Intermediate certificate. It is a runtime engine of SPIFFE. 
2. It consisits of one server and then there are agents.
3. The agents run as daemon set or sidecars along with the pod.
4. The nodes in the ecosystem having the SPIFFE implemented, then the nodes get the certificate or authority bundle from the servers.
5. The agents are responsible for providing the certificate to the workloads running on the node.
6. The nodes and workloads register to the server via a process call attestation.
7. Node attest themselves using the plugin for AWS/GCP cloud provide if running in them or they can use the unique id to the node.
8. The workloads running on the machine will get the certificate from the agents which will be exposed via the socket.

## Reference

1. https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/ 
2. https://spiffe.io/docs/latest/spire-about/spire-concepts/
3. https://spiffe.io/docs/latest/spire-about/spire-concepts/#workload-registration
4. https://spiffe.io/docs/latest/spiffe-about/ecosystem/