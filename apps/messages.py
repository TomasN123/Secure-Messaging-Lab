import json

LINES = ("line1", "line2")
MACHINES = tuple(f"machine{i}" for i in range(1, 6))


def all_machines() -> list[tuple[str, str]]:
    return [(line, machine) for line in LINES for machine in MACHINES]


def topic_for(line: str, machine: str, kind: str) -> str:
    return f"{line}.{machine}.{kind}"


def encode(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode()


def decode(body: bytes) -> dict:
    return json.loads(body)
