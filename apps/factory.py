import os

from broker import Broker


def make_broker(declare_topology: bool = False) -> Broker:
    kind = os.getenv("BROKER", "rabbit")
    if kind == "rabbit":
        from rabbit_broker import RabbitBroker, read_env_file
        path = os.getenv("CREDENTIALS_FILE", "/vault/secrets/rabbit.env")
        return RabbitBroker(
            host=os.getenv("RABBITMQ_HOST", "rabbit"),
            port=int(os.getenv("RABBITMQ_PORT", "5672")),
            credentials=lambda: read_env_file(path),
            declare_topology=declare_topology)
    # phase 12: add the "kafka" branch here
    raise ValueError(f"unknown BROKER={kind!r}")
