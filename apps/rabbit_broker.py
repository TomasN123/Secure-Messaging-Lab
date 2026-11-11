import logging
import threading
from typing import Callable

import pika
from pika.exceptions import AMQPError

from broker import Broker, MessageHandler

from prometheus_client import Counter
ACCOUNT_ROTATIONS = Counter(
    "broker_account_rotations_total",
    "Connections made with a different account than the previous one")
CONNECT_FAILURES = Counter(
    "broker_connect_failures_total", "Failed connection attempts")

log = logging.getLogger("rabbit")

PREFIX = "plant."
EXCHANGE = PREFIX + "messages"
RECONNECT_SECONDS = 3

Credentials = Callable[[], tuple[str, str]]


def read_env_file(path: str) -> tuple[str, str]:
    """Read RABBITMQ_USERNAME / RABBITMQ_PASSWORD written by Vault Agent."""
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                values[key] = value
    return values["RABBITMQ_USERNAME"], values["RABBITMQ_PASSWORD"]


class RabbitBroker(Broker):
    def __init__(self, host: str, port: int, credentials: Credentials,
                 declare_topology: bool = False, persistent: bool = True,
                 confirms: bool = False, prefetch: int = 100):
        self._host, self._port = host, port
        self._credentials = credentials
        self._declare_topology = declare_topology
        self._persistent = persistent
        self._confirms = confirms
        self._prefetch = prefetch
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._pub_lock = threading.Lock()
        self._pub_conn = None
        self._pub_ch = None
        self._last_user = None
        self._user_lock = threading.Lock()

    def _connect(self) -> pika.BlockingConnection:
        user, password = self._credentials()
        with self._user_lock:
            if self._last_user is not None and user != self._last_user:
                ACCOUNT_ROTATIONS.inc()
            self._last_user = user
        params = pika.ConnectionParameters(
            host=self._host, port=self._port,
            credentials=pika.PlainCredentials(user, password),
            heartbeat=30, connection_attempts=1, socket_timeout=5)
        try:
            return pika.BlockingConnection(params)
        except Exception:
            CONNECT_FAILURES.inc()
            raise


    @staticmethod
    def _declare(ch, queue: str, topic: str) -> None:
        ch.exchange_declare(exchange=EXCHANGE, exchange_type="topic", durable=True)
        ch.queue_declare(queue=queue, durable=True)
        ch.queue_bind(queue=queue, exchange=EXCHANGE, routing_key=topic)

    # publish
    def _reset_publisher(self) -> None:
        try:
            if self._pub_conn is not None and self._pub_conn.is_open:
                self._pub_conn.close()
        except Exception:
            pass
        self._pub_conn = self._pub_ch = None

    def _publisher_channel(self):
        if self._pub_ch is None or self._pub_ch.is_closed:
            self._reset_publisher()
            self._pub_conn = self._connect()
            self._pub_ch = self._pub_conn.channel()
            if self._declare_topology:
                self._pub_ch.exchange_declare(
                    exchange=EXCHANGE, exchange_type="topic", durable=True)
            if self._confirms:
                self._pub_ch.confirm_delivery()
        return self._pub_ch

    def publish(self, topic: str, message: bytes) -> None:
        props = pika.BasicProperties(
            delivery_mode=2 if self._persistent else 1,
            content_type="application/json")
        with self._pub_lock:
            for attempt in (1, 2):
                try:
                    self._publisher_channel().basic_publish(
                        exchange=EXCHANGE, routing_key=topic,
                        body=message, properties=props)
                    return
                except (AMQPError, OSError):
                    self._reset_publisher()
                    if attempt == 2:
                        raise

    # subscribe: one thread and one connection per subscription
    def subscribe(self, topic: str, handler: MessageHandler, group: str) -> None:
        t = threading.Thread(target=self._consume_loop,
                             args=(topic, handler, PREFIX + group),
                             name=f"consume-{group}", daemon=True)
        t.start()
        self._threads.append(t)

    def _consume_loop(self, topic: str, handler: MessageHandler, queue: str) -> None:
        def on_message(ch, method, properties, body):
            try:
                handler(method.routing_key, body)
            except Exception:
                log.exception("handler failed for %s, message dropped", method.routing_key)
                ch.basic_nack(method.delivery_tag, requeue=False)
            else:
                ch.basic_ack(method.delivery_tag)

        while not self._stop.is_set():
            conn = None
            try:
                conn = self._connect()
                ch = conn.channel()
                if self._declare_topology:
                    self._declare(ch, queue, topic)
                ch.basic_qos(prefetch_count=self._prefetch)
                ch.basic_consume(queue=queue, on_message_callback=on_message)
                log.info("consuming %s (%s)", queue, topic)
                while not self._stop.is_set():
                    conn.process_data_events(time_limit=1)
            except Exception as exc:
                log.warning("consumer %s: %s; retry in %ds", queue, exc, RECONNECT_SECONDS)
                self._stop.wait(RECONNECT_SECONDS)
            finally:
                try:
                    if conn is not None and conn.is_open:
                        conn.close()
                except Exception:
                    pass

    def provision(self, topic: str, group: str) -> None:
        conn = self._connect()
        try:
            self._declare(conn.channel(), PREFIX + group, topic)
        finally:
            conn.close()

    def close(self) -> None:
        self._stop.set()
        for t in self._threads:
            t.join(timeout=5)
        with self._pub_lock:
            self._reset_publisher()
