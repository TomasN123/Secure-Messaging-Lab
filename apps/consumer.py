import logging
import signal
import threading
import time
from collections import defaultdict, deque

from factory import make_broker
from messages import all_machines, decode, encode, topic_for

from prometheus_client import Counter, Histogram

from metrics import start_metrics_server

RECEIVED = Counter("cons_messages_received_total", "Messages received", ["kind"])
LATENCY = Histogram(
    "cons_latency_seconds", "Time from sent_at to receive", ["kind"],
    buckets=(0.001, 0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))
GAPS = Counter("cons_gaps_total", "Missing sequence numbers")
DUPLICATES = Counter("cons_duplicates_total", "Repeated or reordered sequence numbers")
PARTS = Counter("cons_parts_total", "Finished parts", ["quality"])


log = logging.getLogger("consumer")

REPORT_SECONDS = 10


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.count = defaultdict(int)
        self.latency = defaultdict(lambda: deque(maxlen=2000))
        self.last_seq: dict = {}
        self.gaps = 0
        self.duplicates = 0
        self.quality = defaultdict(int)

    def record(self, kind: str, payload: dict, received_at: float) -> None:
        key = (payload["run"], payload["line"], payload["machine"], kind)
        seq = payload["seq"]
        with self.lock:
            latency = received_at - payload["sent_at"]
            self.count[kind] += 1
            self.latency[kind].append(latency)
            RECEIVED.labels(kind).inc()
            LATENCY.labels(kind).observe(latency)
            last = self.last_seq.get(key, 0)
            if last and seq > last + 1:
                self.gaps += seq - last - 1
                GAPS.inc(seq - last - 1)
            elif last and seq <= last:
                self.duplicates += 1
                DUPLICATES.inc()
            self.last_seq[key] = max(last, seq)
            if kind == "result":
                self.quality[payload.get("quality")] += 1
                PARTS.labels(payload.get("quality")).inc()

    def report(self) -> None:
        with self.lock:
            parts = []
            for kind in sorted(self.count):
                lat = sorted(self.latency[kind])
                p50 = lat[len(lat) // 2] * 1000
                p95 = lat[min(len(lat) - 1, int(len(lat) * 0.95))] * 1000
                parts.append(f"{kind}={self.count[kind]} (p50 {p50:.0f} ms, p95 {p95:.0f} ms)")
            log.info("%s | gaps=%d duplicates=%d quality=%s",
                     ", ".join(parts) or "no messages yet",
                     self.gaps, self.duplicates, dict(self.quality))


def provision_commands(broker, stop: threading.Event) -> None:
    """Command queues must exist before the simulator (no configure right) consumes."""
    for line, machine in all_machines():
        while not stop.is_set():
            try:
                broker.provision(topic_for(line, machine, "command"),
                                 group=f"cmd.{line}.{machine}")
                break
            except Exception as exc:
                log.warning("provision failed: %s; retry in 5 s", exc)
                stop.wait(5)


def send_reset(broker, payload: dict) -> None:
    cmd = {"command": "RESET", "sent_at": time.time(), "reason": "fault"}
    try:
        broker.publish(topic_for(payload["line"], payload["machine"], "command"),
                       encode(cmd))
    except Exception as exc:
        log.warning("could not send RESET: %s", exc)


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("pika").setLevel(logging.WARNING)
    start_metrics_server(8001)
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())

    stats = Stats()
    with make_broker(declare_topology=True) as broker:
        provision_commands(broker, stop)

        def handler_for(kind: str):
            def handler(topic: str, body: bytes) -> None:
                received_at = time.time()
                payload = decode(body)
                stats.record(kind, payload, received_at)
                # the consumer plays MES: a faulted machine gets a RESET command
                if kind == "state" and payload.get("to") == "FAULT":
                    send_reset(broker, payload)
            return handler

        for kind in ("telemetry", "state", "result"):
            broker.subscribe(f"*.*.{kind}", handler_for(kind), group=f"consumer.{kind}")

        while not stop.wait(REPORT_SECONDS):
            stats.report()


if __name__ == "__main__":
    main()
