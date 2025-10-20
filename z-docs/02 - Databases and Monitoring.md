# Databases

## Postgres

I'm using Postgres as my database of choice, since it's incredibly popular and for hireability. It's well documented, open source, and thinks like supabase work well if you just slap it on top of it. I might consider adding a NoSQL and/or caching database in the future, but for 99% of CRUD tasks Postgres will do great.
`kubectl create namespace database`
using bitnami's helm chart: `helm repo add bitnami https://charts.bitnami.com/bitnami` with `helm install postgres bitnami/postgresql -f postgres-values.yaml -n databases`

## Monitoring

Classic Prometheus + Grafana is the way to go for monitoring.
