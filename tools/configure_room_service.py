"""Set the public room service URL before exporting a release."""

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit


def deployed_url(path: Path) -> str:
    for line in reversed(path.read_text(encoding="utf-8").splitlines()):
        deployment = json.loads(line)
        if deployment.get("type") == "deploy":
            for target in deployment.get("targets", []):
                host = urlsplit(target).hostname or ""
                if target.startswith("https://") and host.endswith(".workers.dev"):
                    return target
    raise SystemExit("Wrangler reported no workers.dev URL. Enable the account's workers.dev subdomain.")


def configure(url: str, project: Path) -> None:
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise SystemExit("The production room service must be a public HTTPS URL.")
    text = project.read_text(encoding="utf-8")
    replacement = "network/room_service=" + json.dumps(url.rstrip("/"))
    text, matches = re.subn(r"^network/room_service=.*$", lambda _: replacement, text, flags=re.MULTILINE)
    if matches != 1:
        raise SystemExit("Expected exactly one room service setting in project.godot.")
    project.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--url")
    source.add_argument("--wrangler-output", type=Path)
    parser.add_argument("--project", type=Path, default=Path("project.godot"))
    args = parser.parse_args()
    url = args.url if args.url else deployed_url(args.wrangler_output)
    configure(url, args.project)
    print(url.rstrip("/"))
