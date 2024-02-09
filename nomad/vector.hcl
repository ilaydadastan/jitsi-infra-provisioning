variable "dc" {
  type = list(string)
}

variable "top_level_domain" {
  type = string
  default = "jitsi.net"
}

job "vector" {
  datacenters = var.dc
  # system job, runs on all nodes
  type = "system"
  update {
    min_healthy_time = "10s"
    healthy_deadline = "5m"
    progress_deadline = "10m"
    auto_revert = true
  }
  group "vector" {
    count = 1
    restart {
      attempts = 3
      interval = "10m"
      delay = "30s"
      mode = "delay"
    }
    network {
      port "api" {
        to = 8686
      }
      port "syslog" {
        static = 9000
      }
    }
    # docker socket volume
    volume "docker-sock-ro" {
      type = "host"
      source = "docker-sock-ro"
      read_only = true
    }
    ephemeral_disk {
      size    = 500
      sticky  = true
    }
    task "vector" {
      driver = "docker"
      config {
        image = "timberio/vector:0.28.1-alpine"
        ports = ["api","syslog"]
        volumes = [
          "/var/log/syslog:/var/log/syslog:ro",
        ]
      }
      # docker socket volume mount
      volume_mount {
        volume = "docker-sock-ro"
        destination = "/var/run/docker.sock"
        read_only = true
      }
      # Vector won't start unless the sinks(backends) configured are healthy
      env {
        VECTOR_CONFIG = "local/vector.toml"
        VECTOR_REQUIRE_HEALTHY = "true"
      }
      # resource limits are a good idea because you don't want your log collection to consume all resources available
      resources {
        cpu    = 500 # 500 MHz
        memory = 256 # 256MB
      }
      # template with Vector's configuration
      template {
        destination = "local/vector.toml"
        change_mode   = "signal"
        change_signal = "SIGHUP"
        # overriding the delimiters to [[ ]] to avoid conflicts with Vector's native templating, which also uses {{ }}
        left_delimiter = "[["
        right_delimiter = "]]"
        data=<<EOH
          data_dir = "alloc/data/vector/"
          [api]
            enabled = true
            address = "0.0.0.0:8686"
            playground = true
          [sources.logs]
            type = "docker_logs"
          [sources.syslog]
            type = "syslog"
            address = "0.0.0.0:9000"
            mode = "tcp"
          [sinks.loki_syslog]
            remove_timestamp = false
            type = "loki"
            inputs = ["syslog"]
            endpoint = "https://[[ env "meta.environment" ]]-[[ env "meta.cloud_region" ]]-loki.${var.top_level_domain}"
            encoding.codec = "json"
            healthcheck.enabled = true
            # since . is used by Vector to denote a parent-child relationship, and Nomad's Docker labels contain ".",
            # we need to escape them twice, once for TOML, once for Vector
            # remove fields that have been converted to labels to avoid having the field twice
            # remove_label_fields = true
                [sinks.loki_syslog.labels]
                    alloc = "[[ env "meta.cloud_instance_id" ]]"
                    job = "syslog"
                    task = "{{ .appname }}"
                    group = "syslog"
                    namespace = "system"
                    node = "[[ env "node.unique.name" ]]"
                    region = "[[ env "meta.cloud_region" ]]"
          [transforms.message_to_structure]
            type = "remap"
            inputs = ["logs"]
            source = """
            structured =
              parse_json(.message) ??
              parse_syslog(.message) ??
              parse_common_log(.message) ??
              parse_regex(.message, r'^(?P<timestamp>\\d+/\\d+/\\d+ \\d+:\\d+:\\d+) \\[(?P<severity>\\w+)\\] (?P<pid>\\d+)#(?P<tid>\\d+):(?: \\*(?P<connid>\\d+))? (?P<message>.*)$') ??
              {}
            . = merge(., structured) ?? ."""
          [sinks.out]
            type = "console"
            inputs = [ "message_to_structure" ]
            encoding.codec = "json"
          [sinks.loki]
            remove_timestamp = false
            type = "loki"
            inputs = ["message_to_structure"]
            endpoint = "https://[[ env "meta.environment" ]]-[[ env "meta.cloud_region" ]]-loki.${var.top_level_domain}"
            encoding.codec = "json"
            healthcheck.enabled = true
            # since . is used by Vector to denote a parent-child relationship, and Nomad's Docker labels contain ".",
            # we need to escape them twice, once for TOML, once for Vector
            # remove fields that have been converted to labels to avoid having the field twice
            remove_label_fields = true
                [sinks.loki.labels]
                    alloc = "{{ label.\"com.hashicorp.nomad.alloc_id\" }}"
                    job = "{{ label.\"com.hashicorp.nomad.job_name\" }}"
                    task = "{{ label.\"com.hashicorp.nomad.task_name\" }}"
                    group = "{{ label.\"com.hashicorp.nomad.task_group_name\" }}"
                    namespace = "{{ label.\"com.hashicorp.nomad.namespace\" }}"
                    node = "{{ label.\"com.hashicorp.nomad.node_name\" }}"
                    region = "[[ env "meta.cloud_region" ]]"
        EOH
      }
      service {
        check {
          port     = "api"
          type     = "http"
          path     = "/health"
          interval = "30s"
          timeout  = "5s"
        }
      }
      kill_timeout = "30s"
    }
  }
}