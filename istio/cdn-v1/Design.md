                       api.poc.local:8080
                              |
                              v
                         NGINX / CDN
                              |
               +--------------+--------------+
               |              |              |
              /*            /api*          /user*
               |              |              |
               v              +------+-------+
          Flocci S3                   |
          test-bucket                 v
                              Istio Ingress
                                     |
                         +-----------+-----------+
                         |                       |
                       /api*                   /user*
                         |                       |
                         v                       v
                     service-a               service-b