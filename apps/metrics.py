import os

from prometheus_client import start_http_server

def start_metrics_server(default_port: int) -> None:
    """Expose /metrics on all interfaces of the container (no ports: in compose)."""
    start_http_server(int(os.getenv("METRICS_PORT", default_port)))
