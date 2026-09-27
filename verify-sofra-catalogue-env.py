#!/usr/bin/env python3
"""Validate resolved catalogue limits and pool settings before a Sofra rollout."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
RATE_LIMIT_KEYS = (
    "CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS",
    "CATALOGUE_READ_RATE_LIMIT_WINDOW_MS",
)
POOL_BOUNDS = {
    "CATALOGUE_POOL_MAX": (1, 10),
    "CATALOGUE_POOL_CONNECTION_TIMEOUT_MS": (100, 60_000),
    "CATALOGUE_POOL_IDLE_TIMEOUT_MS": (1_000, 600_000),
}
ENVIRONMENT_KEYS = RATE_LIMIT_KEYS + tuple(POOL_BOUNDS)
SOFRA_SERVICES = ("sofra", "sofra-staging")
MAX_SAFE_INTEGER = 9_007_199_254_740_991


def positive_safe_integer(value: object) -> bool:
    if not isinstance(value, str) or re.fullmatch(r"[1-9]\d*", value, flags=re.ASCII) is None:
        return False
    if len(value) > len(str(MAX_SAFE_INTEGER)):
        return False
    return int(value) <= MAX_SAFE_INTEGER


def bounded_pool_integer(value: object, minimum: int, maximum: int) -> bool:
    return (
        positive_safe_integer(value)
        and minimum <= int(value) <= maximum
    )


def validate_service_environment(
    service_name: str,
    service: object,
) -> tuple[dict[str, str], list[str]]:
    environment = service.get("environment") if isinstance(service, dict) else None
    if not isinstance(environment, dict):
        return {}, [f"{service_name} has no resolved environment map."]

    values: dict[str, str] = {}
    problems: list[str] = []
    for key in RATE_LIMIT_KEYS:
        value = environment.get(key)
        if not positive_safe_integer(value):
            problems.append(f"{service_name} requires {key} to be a positive safe integer.")
        elif isinstance(value, str):
            values[key] = value
    for key, (minimum, maximum) in POOL_BOUNDS.items():
        value = environment.get(key)
        if not bounded_pool_integer(value, minimum, maximum):
            problems.append(
                f"{service_name} requires {key} to be an integer between {minimum} and {maximum}."
            )
        elif isinstance(value, str):
            values[key] = value
    return values, problems


def validate_compose_config(config: object) -> list[str]:
    if not isinstance(config, dict) or not isinstance(config.get("services"), dict):
        return ["Compose config has no services object."]

    services = config["services"]
    validated: dict[str, dict[str, str]] = {}
    problems: list[str] = []
    for service_name in SOFRA_SERVICES:
        values, service_problems = validate_service_environment(
            service_name,
            services.get(service_name),
        )
        validated[service_name] = values
        problems.extend(service_problems)

    if len(validated) == len(SOFRA_SERVICES) and validated["sofra"] != validated["sofra-staging"]:
        problems.append("sofra and sofra-staging must use the same catalogue limits and pool settings.")
    return problems


def main() -> int:
    env_file = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".env"
    if len(sys.argv) > 2:
        print("usage: verify-sofra-catalogue-env.py [box-env-file]", file=sys.stderr)
        return 2
    if not env_file.is_file():
        print(f"FAIL: box environment file does not exist: {env_file}", file=sys.stderr)
        return 1

    # Validate the box .env as the source of truth, even if the invoking shell has
    # catalogue settings exported. Compose resolves the file; its rendered secrets
    # never reach the terminal.
    compose_environment = os.environ.copy()
    for key in ENVIRONMENT_KEYS:
        compose_environment.pop(key, None)
    command = [
        "docker", "compose",
        "--project-directory", str(ROOT),
        "--env-file", str(env_file),
        "--profile", "sofra",
        "--profile", "sofra-staging",
        "-f", str(ROOT / "docker-compose.prod.yml"),
        "config", "--format", "json",
    ]
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            env=compose_environment,
        )
    except OSError:
        print("FAIL: docker compose could not be started.", file=sys.stderr)
        return 1
    if result.returncode != 0:
        print("FAIL: docker compose could not resolve the box configuration.", file=sys.stderr)
        return 1
    try:
        config = json.loads(result.stdout)
    except json.JSONDecodeError:
        print("FAIL: docker compose returned invalid JSON configuration.", file=sys.stderr)
        return 1

    problems = validate_compose_config(config)
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        return 1

    print("OK: both Sofra services have valid, matching catalogue limits and pool settings.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
