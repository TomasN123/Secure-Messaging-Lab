from abc import ABC, abstractmethod
from typing import Callable

MessageHandler = Callable[[str, bytes], None]


class Broker(ABC):
    """Broker-neutral interface used by the simulator and the consumer.

    Topics look like ``line1.machine3.telemetry`` (no ``plant.`` prefix).
    ``*`` matches exactly one word in a subscribe topic. Adapters add
    whatever prefixes their broker needs. Messages are raw bytes, because
    both RabbitMQ and Kafka transport bytes; JSON is done by the caller.
    Delivery is at-least-once.
    """

    @abstractmethod
    def publish(self, topic: str, message: bytes) -> None:
        """Send ``message`` to ``topic``. Raises if it cannot be handed over."""

    @abstractmethod
    def subscribe(self, topic: str, handler: MessageHandler, group: str) -> None:
        """Start consuming in the background and return immediately.

        ``handler(topic, body)`` runs in an adapter thread. If it raises, the
        message is logged and dropped. ``group`` is the queue name (RabbitMQ)
        or consumer group (Kafka); consumers with the same group share messages.
        """

    def provision(self, topic: str, group: str) -> None:
        """Create the destination for (topic, group) if missing. Default: no-op."""

    @abstractmethod
    def close(self) -> None:
        """Stop all background threads and close connections."""

    def __enter__(self) -> "Broker":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
