import logging
import os
import queue
import random
import signal
import threading
import time
from collections import defaultdict

from factory import make_broker
from messages import all_machines, decode, encode, topic_for

from prometheus_client import Counter

from metrics import start_metrics_server

SENT = Counter("sim_messages_sent_total", "Messages handed to the broker", ["kind"])
DROPPED = Counter("sim_messages_dropped_total", "Messages that failed to publish", ["kind"])
COMMANDS = Counter("sim_commands_received_total", "Commands received from MES", ["command"])


log = logging.getLogger("simulator")

TICK_SECONDS = float(os.getenv("TICK_SECONDS", "1.0"))
FAULT_AUTORECOVER = float(os.getenv("FAULT_AUTORECOVER_SECONDS", "120"))
CYCLE_RANGE = (3.0, 6.0)
SCRAP_RATE = 0.05
FAULT_RATE = 0.01
RUN_ID = int(time.time())  # lets the consumer tell restarts from duplicates

TRANSITIONS = {("FAULT", "RESET"): "IDLE",
               ("IDLE", "START"): "RUNNING",
               ("RUNNING", "STOP"): "IDLE"}


class Counters:
    sent = 0
    dropped = 0


class Machine:
    def __init__(self, line: str, name: str):
        self.line, self.name = line, name
        self.state = "IDLE"
        self.state_since = time.time()
        self.cycle_time = 0.0
        self.cycle_due = 0.0
        self.parts = 0
        self.seq = defaultdict(int)
        self.commands: queue.SimpleQueue = queue.SimpleQueue()

    def _send(self, broker, kind: str, data: dict) -> None:
        self.seq[kind] += 1
        payload = {"run": RUN_ID, "line": self.line, "machine": self.name,
                   "type": kind, "seq": self.seq[kind],
                   "sent_at": time.time(), **data}
        try:
            broker.publish(topic_for(self.line, self.name, kind), encode(payload))
            Counters.sent += 1
            SENT.labels(kind).inc()
        except Exception as exc:
            Counters.dropped += 1
            DROPPED.labels(kind).inc()
            log.warning("publish failed (%s.%s %s): %s", self.line, self.name, kind, exc)

    def _schedule_cycle(self, now: float) -> None:
        self.cycle_time = random.uniform(*CYCLE_RANGE)
        self.cycle_due = now + self.cycle_time

    def _set_state(self, broker, new: str, cause: str) -> None:
        old, now = self.state, time.time()
        self.state, self.state_since = new, now
        if new == "RUNNING":
            self._schedule_cycle(now)
        self._send(broker, "state", {"from": old, "to": new, "cause": cause})

    def _handle_commands(self, broker) -> None:
        while True:
            try:
                cmd = self.commands.get_nowait()
            except queue.Empty:
                return
            name = cmd.get("command")
            COMMANDS.labels(name or "unknown").inc()
            delay_ms = (time.time() - cmd.get("sent_at", time.time())) * 1000
            new = TRANSITIONS.get((self.state, name))
            log.info("%s.%s got %s after %.0f ms (state %s)",
                     self.line, self.name, name, delay_ms, self.state)
            if new:
                self._set_state(broker, new, f"command:{name}")

    def _maybe_change_state(self, broker, now: float) -> None:
        r = random.random()
        if self.state == "IDLE" and r < 0.1:
            self._set_state(broker, "RUNNING", "auto")
        elif self.state == "RUNNING":
            if r < FAULT_RATE:
                self._set_state(broker, "FAULT", "fault")
            elif r < FAULT_RATE + 0.005:
                self._set_state(broker, "IDLE", "auto")
        elif self.state == "FAULT" and now - self.state_since > FAULT_AUTORECOVER:
            self._set_state(broker, "IDLE", "auto-recover")

    def _telemetry(self) -> dict:
        running = self.state == "RUNNING"
        return {"state": self.state,
                "temperature_c": round(random.gauss(72 if running else 35, 2), 2),
                "vibration_mm_s": round(abs(random.gauss(2.5 if running else 0.2, 0.4)), 3),
                "spindle_rpm": int(random.gauss(12000, 150)) if running else 0}

    def step(self, broker) -> None:
        now = time.time()
        self._handle_commands(broker)
        self._maybe_change_state(broker, now)
        self._send(broker, "telemetry", self._telemetry())
        if self.state == "RUNNING" and now >= self.cycle_due:
            self.parts += 1
            quality = "SCRAP" if random.random() < SCRAP_RATE else "OK"
            self._send(broker, "result", {
                "part_id": f"{self.line}-{self.name}-{self.parts}",
                "quality": quality, "cycle_time_s": round(self.cycle_time, 2)})
            self._schedule_cycle(now)


def command_handler(machine: Machine):
    def handler(topic: str, body: bytes) -> None:
        machine.commands.put(decode(body))
    return handler


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("pika").setLevel(logging.WARNING)
    start_metrics_server(8000)
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())

    machines = [Machine(line, name) for line, name in all_machines()]
    with make_broker(declare_topology=False) as broker:
        for m in machines:
            broker.subscribe(topic_for(m.line, m.name, "command"),
                             command_handler(m), group=f"cmd.{m.line}.{m.name}")
        last_report = time.monotonic()
        while not stop.is_set():
            started = time.monotonic()
            for m in machines:
                m.step(broker)
            if started - last_report >= 10:
                log.info("sent=%d dropped=%d", Counters.sent, Counters.dropped)
                last_report = started
            stop.wait(max(0.0, TICK_SECONDS - (time.monotonic() - started)))


if __name__ == "__main__":
    main()
