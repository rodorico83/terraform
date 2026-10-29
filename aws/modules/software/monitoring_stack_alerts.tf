resource "kubectl_manifest" "postgres_prometheus_rules" {
  count           = var.enable_monitoring ? 1 : 0
  validate_schema = false
  yaml_body = jsonencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "postgres-database-alerts"
      namespace = "monitoring"
      labels = {
        role    = "alert-rules"
        release = "kube-prometheus-stack"
      }
    }
    spec = {
      groups = [
        {
          name = "PostgresDatabaseAlerts"
          rules = [
            # ----------------------------------------------------------------------
            # 1. DISPONIBILIDAD Y CONEXIÓN
            # ----------------------------------------------------------------------
            {
              alert = "PostgresExporterDown"
              expr  = "pg_up == 0"
              for   = "1m"
              labels = {
                severity = "critical"
                tier     = "database"
              }
              annotations = {
                summary     = "Instancia de PostgreSQL / Exporter inaccesible"
                description = "El postgres-exporter no puede conectar con la base de datos PostgreSQL en el endpoint configurado."
              }
            },

            # ----------------------------------------------------------------------
            # 2. SATURACIÓN DE CONEXIONES (SRE Saturation)
            # ----------------------------------------------------------------------
            {
              alert = "PostgresConnectionsLimitHigh"
              expr  = "(sum(pg_stat_database_numbackends) / sum(pg_settings_max_connections)) * 100 > 80"
              for   = "3m"
              labels = {
                severity = "warning"
                tier     = "database"
              }
              annotations = {
                summary     = "Conexiones de PostgreSQL al {{ $value | printf \"%.1f\" }}% del límite"
                description = "El número de conexiones activas ha superado el 80% de `max_connections`. Riesgo de rechazo de nuevas conexiones."
              }
            },
            {
              alert = "PostgresConnectionsLimitCritical"
              expr  = "(sum(pg_stat_database_numbackends) / sum(pg_settings_max_connections)) * 100 > 92"
              for   = "1m"
              labels = {
                severity = "critical"
                tier     = "database"
              }
              annotations = {
                summary     = "CRÍTICO: Conexiones de PostgreSQL al {{ $value | printf \"%.1f\" }}% del límite"
                description = "La base de datos está a punto de agotar su pool de conexiones (`max_connections`). Intervención inmediata requerida."
              }
            },

            # ----------------------------------------------------------------------
            # 3. REPLICACIÓN Y RECURSOS INTERNOS (Deadlocks & Lock Wait)
            # ----------------------------------------------------------------------
            {
              alert = "PostgresDeadlocksDetected"
              expr  = "increase(pg_stat_database_deadlocks[5m]) > 0"
              for   = "0m"
              labels = {
                severity = "warning"
                tier     = "database"
              }
              annotations = {
                summary     = "Deadlock detectado en PostgreSQL"
                description = "Se ha detectado al menos un bloqueo mutuo (deadlock) en la base de datos en los últimos 5 minutos."
              }
            },
            {
              alert = "PostgresHighSlowQueriesCount"
              expr  = "rate(pg_stat_activity_max_tx_duration{state=\"active\"}[5m]) > 20"
              for   = "2m"
              labels = {
                severity = "warning"
                tier     = "database"
              }
              annotations = {
                summary     = "Transacciones de larga duración acumuladas en PostgreSQL"
                description = "Hay transacciones activas reteniendo bloqueos por más tiempo del esperado."
              }
            },

            # ----------------------------------------------------------------------
            # 4. RENDIMIENTO Y ERRORES DE TRANSACCIÓN (Burn Rate SLO)
            # ----------------------------------------------------------------------
            {
              alert = "PostgresHighRollbackRateBurnQuick"
              expr  = "(sum(rate(pg_stat_database_xact_rollback[1h])) / (sum(rate(pg_stat_database_xact_commit[1h])) + sum(rate(pg_stat_database_xact_rollback[1h])))) > (1 - 0.995) * 14.4"
              for   = "2m"
              labels = {
                severity = "critical"
                tier     = "database"
              }
              annotations = {
                summary     = "Consumo crítico de Error Budget por Rollbacks en PostgreSQL (Burn Rate > 14.4x)"
                description = "La tasa de transacciones abortadas/rollbacks respecto al total supera el límite permitido para mantener el SLO."
              }
            },

            # ----------------------------------------------------------------------
            # 5. ALMACENAMIENTO Y CAPACIDAD (Revisión de Disco / Replication Lag)
            # ----------------------------------------------------------------------
            {
              alert = "PostgresReplicationLagHigh"
              expr  = "pg_replication_lag > 30"
              for   = "3m"
              labels = {
                severity = "warning"
                tier     = "database"
              }
              annotations = {
                summary     = "Lag de réplica elevado en PostgreSQL"
                description = "El tiempo de retraso de sincronización con la réplica supera los 30 segundos."
              }
            },

            # ----------------------------------------------------------------------
            # 6. LATENCIA Y RENDIMIENTO DE CONSULTAS (Query Latency)
            # ----------------------------------------------------------------------
            {
              alert = "PostgresQueryLatencyHigh"
              expr  = "rate(pg_stat_statements_seconds_sum[5m]) / rate(pg_stat_statements_seconds_count[5m]) > 0.1"
              for   = "3m"
              labels = {
                severity = "warning"
                tier     = "database"
              }
              annotations = {
                summary     = "Latencia media elevada en consultas de PostgreSQL"
                description = "El tiempo medio de ejecución de las consultas en la base de datos supera los 100ms durante los últimos 3 minutos."
              }
            }
          ]
        }
      ]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}



/*resource "kubectl_manifest" "postgres_prometheus_rules" {
  count           = var.enable_monitoring ? 1 : 0
  validate_schema = false
  yaml_body = <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: postgres-database-alerts
  namespace: monitoring
  labels:
    role: alert-rules
    release: kube-prometheus-stack
spec:
  groups:
    - name: PostgresDatabaseAlerts
      rules:

        # ----------------------------------------------------------------------
        # 1. DISPONIBILIDAD Y CONEXIÓN
        # ----------------------------------------------------------------------
        - alert: PostgresExporterDown
          expr: pg_up == 0
          for: 1m
          labels:
            severity: critical
            tier: database
          annotations:
            summary: "Instancia de PostgreSQL / Exporter inaccesible"
            description: "El postgres-exporter no puede conectar con la base de datos PostgreSQL en el endpoint configurado."

        # ----------------------------------------------------------------------
        # 2. SATURACIÓN DE CONEXIONES (SRE Saturation)
        # ----------------------------------------------------------------------
        - alert: PostgresConnectionsLimitHigh
          expr: (sum(pg_stat_database_numbackends) / sum(pg_settings_max_connections)) * 100 > 80
          for: 3m
          labels:
            severity: warning
            tier: database
          annotations:
            summary: "Conexiones de PostgreSQL al {{ $value | printf \"%.1f\" }}% del límite"
            description: "El número de conexiones activas ha superado el 80% de `max_connections`. Riesgo de rechazo de nuevas conexiones."

        - alert: PostgresConnectionsLimitCritical
          expr: (sum(pg_stat_database_numbackends) / sum(pg_settings_max_connections)) * 100 > 92
          for: 1m
          labels:
            severity: critical
            tier: database
          annotations:
            summary: "CRÍTICO: Conexiones de PostgreSQL al {{ $value | printf \"%.1f\" }}% del límite"
            description: "La base de datos está a punto de agotar su pool de conexiones (`max_connections`). Intervención inmediata requerida."

        # ----------------------------------------------------------------------
        # 3. REPLICACIÓN Y RECURSOS INTERNOS (Deadlocks & Lock Wait)
        # ----------------------------------------------------------------------
        - alert: PostgresDeadlocksDetected
          expr: increase(pg_stat_database_deadlocks[5m]) > 0
          for: 0m
          labels:
            severity: warning
            tier: database
          annotations:
            summary: "Deadlock detectado en PostgreSQL"
            description: "Se ha detectado al menos un bloqueo mutuo (deadlock) en la base de datos en los últimos 5 minutos."

        - alert: PostgresHighSlowQueriesCount
          expr: rate(pg_stat_activity_max_tx_duration{state="active"}[5m]) > 20
          for: 2m
          labels:
            severity: warning
            tier: database
          annotations:
            summary: "Transacciones de larga duración acumuladas en PostgreSQL"
            description: "Hay transacciones activas reteniendo bloqueos por más tiempo del esperado."

        # ----------------------------------------------------------------------
        # 4. RENDIMIENTO Y ERRORES DE TRANSACCIÓN (Burn Rate SLO)
        # ----------------------------------------------------------------------
        - alert: PostgresHighRollbackRateBurnQuick
          expr: |
            (
              sum(rate(pg_stat_database_xact_rollback[1h]))
              /
              (sum(rate(pg_stat_database_xact_commit[1h])) + sum(rate(pg_stat_database_xact_rollback[1h])))
            ) > (1 - 0.995) * 14.4
          for: 2m
          labels:
            severity: critical
            tier: database
          annotations:
            summary: "Consumo crítico de Error Budget por Rollbacks en PostgreSQL (Burn Rate > 14.4x)"
            description: "La tasa de transacciones abortadas/rollbacks respecto al total supera el límite permitido para mantener el SLO."

        # ----------------------------------------------------------------------
        # 5. ALMACENAMIENTO Y CAPACIDAD (Revisión de Disco / Replication Lag)
        # ----------------------------------------------------------------------
        - alert: PostgresReplicationLagHigh
          expr: pg_replication_lag > 30
          for: 3m
          labels:
            severity: warning
            tier: database
          annotations:
            summary: "Lag de réplica elevado en PostgreSQL"
            description: "El tiempo de retraso de sincronización con la réplica supera los 30 segundos."

        - alert: PostgresQueryLatencyHigh
          expr: rate(pg_stat_statements_seconds_sum[5m]) / rate(pg_stat_statements_seconds_count[5m]) > 0.1
          for: 3m
          labels:
            severity: warning
            tier: database
          annotations:
            summary: "Latencia media elevada en consultas de PostgreSQL"
            description: "El tiempo medio de ejecución de las consultas en la base de datos supera los 100ms durante los últimos 3 minutos."

YAML

  depends_on = [helm_release.kube_prometheus_stack]
}*/