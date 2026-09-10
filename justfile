set shell := ["bash", "-uc"]
set dotenv-load := false

stack_list := "traefik cloudflared media-server homarr"

# Show available recipes
default:
    just --list

# Create the shared Docker networks (idempotent)
networks:
    docker network inspect internal >/dev/null 2>&1 || docker network create internal
    docker network inspect external >/dev/null 2>&1 || docker network create external

# Validate every compose file against the docker compose schema
validate:
    @for s in {{ stack_list }}; do \
        echo "-- stacks/$$s/compose.yaml" \
        && docker compose -f "stacks/$$s/compose.yaml" config -q || exit 1 \
    ; done

# Run all pre-commit format/lint hooks (prettier, shfmt, gitleaks, hygiene).
# One-time setup: pipx install pre-commit && pre-commit install && brew install gitleaks
fmt:
    pre-commit run --all-files

# Pull fresh images for every stack
pull:
    @for s in {{ stack_list }}; do \
        echo "-- $$s" \
        && docker compose -f "stacks/$$s/compose.yaml" pull \
    ; done

# Update all containers to the images referenced in compose (pull + recreate changed ones)
update-all:
    just pull
    @for s in {{ stack_list }}; do \
        echo "-- $$s" \
        && docker compose -f "stacks/$$s/compose.yaml" up -d \
    ; done

# Update one stack, e.g. `just update traefik`
update stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" pull
    docker compose -f "stacks/{{ stack }}/compose.yaml" up -d

# Recreate one service within a stack (after bumping its tag), e.g. `just up-svc media-server jellyfin`
up-svc stack service:
    docker compose -f "stacks/{{ stack }}/compose.yaml" up -d "{{ service }}"

# Pull + recreate one service within a stack, e.g. `just update-svc media-server jellyfin`
update-svc stack service:
    docker compose -f "stacks/{{ stack }}/compose.yaml" pull "{{ service }}"
    docker compose -f "stacks/{{ stack }}/compose.yaml" up -d "{{ service }}"

# Compare pinned image tags against what the registries publish (read-only)
check-updates:
    #!/usr/bin/env python3
    import json
    import re
    import sys
    import urllib.request

    COMPOSE_FILES = (
        "stacks/traefik/compose.yaml",
        "stacks/cloudflared/compose.yaml",
        "stacks/media-server/compose.yaml",
        "stacks/homarr/compose.yaml",
    )
    VERSION_RE = re.compile(r"^v?[0-9]+(\.[0-9]+){1,4}$")

    def compose_images(path):
        current = None
        images = []
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            m = re.match(r"^  (\w[\w-]+):$", line)
            if m:
                current = m.group(1)
                continue
            m = re.match(r"^    image: (\S+)$", line)
            if m and current:
                images.append((current, m.group(1)))
        return images

    def split_image(image):
        node, _, _ = image.partition("@")
        name, sep, tag = node.partition(":")
        if not sep:
            tag = "latest"
        parts = name.split("/")
        if len(parts) == 1:
            return "docker.io", "library/" + name, tag
        host = parts[0]
        if "." in host or ":" in host or host == "localhost":
            registry, repo = host, "/".join(parts[1:])
            if registry == "lscr.io":
                return "docker.io", name.split("/", 1)[1], tag
            return registry, repo, tag
        return "docker.io", name, tag

    def http_json(url, headers=None, timeout=20):
        req = urllib.request.Request(url, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)

    def latest_docker_hub(repo):
        url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=100&ordering=last_updated"
        try:
            data = http_json(url)
        except Exception:
            return None
        for item in data.get("results", []):
            if VERSION_RE.match(item["name"]):
                return item["name"]
        return None

    def latest_ghcr(repo):
        try:
            token = http_json(f"https://ghcr.io/token?scope=repository:{repo}:pull")["token"]
        except Exception:
            return None
        tags = []
        url = f"https://ghcr.io/v2/{repo}/tags/list?n=10000"
        while url:
            try:
                req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
                with urllib.request.urlopen(req, timeout=20) as resp:
                    tags.extend(json.load(resp).get("tags", []))
                    url = None
                    for link in resp.headers.get("Link", "").split(","):
                        if 'rel="next"' in link:
                            url = link[link.index("<") + 1:link.index(">")]
            except Exception:
                return None
        candidates = sorted((t for t in tags if VERSION_RE.match(t)),
                            key=lambda t: [int(x) for x in re.sub(r"^v", "", t).split(".")])
        return candidates[-1] if candidates else None

    rows = []
    seen = set()
    for path in COMPOSE_FILES:
        for service, image in compose_images(path):
            key = (path, image)
            if key in seen:
                continue
            seen.add(key)
            registry, repo, pinned = split_image(image)
            if registry == "docker.io":
                latest = latest_docker_hub(repo)
            elif registry == "ghcr.io":
                latest = latest_ghcr(repo)
            else:
                latest = "(unsupported registry)"
            latest_v = latest.lstrip("v") if isinstance(latest, str) else None
            if latest_v is None:
                status = "?"
            else:
                status = "up-to-date" if latest_v == pinned.lstrip("v") else "UPDATE"
            rows.append((path, service, image, latest, status))

    headers = ("compose", "service", "image", "latest", "status")
    display = [[r[0], r[1], r[2], "-" if r[3] is None else r[3], r[4]] for r in rows]
    widths = [max(len(str(r[i])) for r in display + [list(headers)]) + 2 for i in range(len(headers))]
    fmt = "  ".join("{%d:<%d}" % (i, widths[i]) for i in range(len(headers)))
    print(fmt.format(*headers))
    print("  ".join("-" * (w - 2) for w in widths))
    for row in display:
        print(fmt.format(*[str(x) for x in row]))

    updates = sum(1 for _, _, _, _, status in display if status == "UPDATE")
    print(f"\n{updates} image(s) with newer tags available.")
    sys.exit(1 if updates else 0)

# List locally available images
images:
    docker images

# Show Docker disk usage (images, containers, volumes)
df:
    docker system df

# Bring the whole stack up (ensures networks exist first)
up: networks
    @for s in {{ stack_list }}; do \
        echo "-- $$s" \
        && docker compose -f "stacks/$$s/compose.yaml" up -d \
    ; done

# Tear the whole stack down
down:
    @for s in {{ stack_list }}; do \
        echo "-- $$s" \
        && docker compose -f "stacks/$$s/compose.yaml" down \
    ; done

# Restart one stack, e.g. `just restart traefik`
restart stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" restart

# Stream logs for one stack, e.g. `just logs media-server`
logs stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" logs -f --tail=100

# Show the resolved compose config for one stack, e.g. `just config homarr`
config stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" config

# List running containers
ps:
    docker ps

# Pre-create + chown service config dirs (run once after first clone)
# SERVICES_DIR defaults to /mnt/storage/docker/data; override with `just dirs SERVICES_DIR=/custom/path`
dirs SERVICES_DIR="/mnt/storage/docker/data" PUID="1000" PGID="1000":
    mkdir -p "{{ SERVICES_DIR }}"/{jellyfin/config,seerr/config,radarr,sonarr,prowlarr,profilarr/config,bazarr/config,decypharr/configs,sabnzbd/config,crowdsec/config,crowdsec/data}
    chown -R "{{ PUID }}":"{{ PGID }}" "{{ SERVICES_DIR }}"
