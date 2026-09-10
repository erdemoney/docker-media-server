set shell := ["bash", "-uc"]
set dotenv-load := false

stack_list := "traefik cloudflared media-server"

# Show available recipes
default:
    just --list

# Copy .env.example → .env for every stack and fill the interactive secrets:
# generates CROWDSEC_BOUNCER_API_KEY, prompts for the Traefik dashboard
# credentials, and walks you through the Cloudflare API + tunnel tokens.
init:
    #!/usr/bin/env bash
    set -euo pipefail

    for s in {{ stack_list }}; do
        if [ -f "stacks/$s/.env" ]; then
            echo "stacks/$s/.env   already exists (skipping create)"
        else
            cp "stacks/$s/.env.example" "stacks/$s/.env"
            echo "stacks/$s/.env   created from example"
        fi
    done
    echo

    get_var() {   # prints the current value of KEY in FILE ('' if unset)
        sed -n "s|^$2=\(.*\)|\1|p" "$1" | tail -n1
    }

    set_var() {   # sets KEY to VALUE in FILE, preserving the rest of the file
        local esc
        esc=$(printf '%s' "$3" | sed -e 's/[&|\\]/\\&/g')
        sed -i "s|^$2=.*|$2=$esc|" "$1"
    }

    open_url() {  # best-effort: open the URL in the default browser
        local url="$1"
        if command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$url" >/dev/null 2>&1 &
            disown || true
        elif command -v open >/dev/null 2>&1; then
            open "$url" >/dev/null 2>&1 &
            disown || true
        else
            echo "    -> open $url in your browser"
        fi
    }

    TRAEFIK_ENV=stacks/traefik/.env

    echo "== CROWDSEC_BOUNCER_API_KEY =="
    if [ -n "$(get_var "$TRAEFIK_ENV" CROWDSEC_BOUNCER_API_KEY)" ]; then
        echo "  already set (stacks/traefik/.env)"
    else
        set_var "$TRAEFIK_ENV" CROWDSEC_BOUNCER_API_KEY "$(openssl rand -hex 32)"
        echo "  generated a random 32-byte key"
    fi
    echo

    echo "== TRAEFIK_DASHBOARD_CREDENTIALS =="
    if [ -n "$(get_var "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_CREDENTIALS)" ]; then
        echo "  already set (stacks/traefik/.env)"
    else
        echo "  htpasswd-style user:hash for the Traefik dashboard."
        printf '  dashboard username (default admin): '
        read -r dash_user || dash_user=""
        printf '  dashboard password (hidden): '
        read -rs dash_pass || dash_pass=""
        printf '\n'
        [ -n "$dash_user" ] || dash_user="admin"
        hash=$(openssl passwd -apr1 "$dash_pass" 2>/dev/null) || hash=""
        case "$hash" in
            \$apr1\$*) : ;;
            *) hash=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$dash_user" "$dash_pass" | cut -d: -f2) ;;
        esac
        set_var "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_CREDENTIALS "'$dash_user:$hash'"
        echo "  set (single-quoted so compose doesn't eat the hash)"
    fi
    echo

    echo "== CF_DNS_API_TOKEN =="
    if [ -n "$(get_var "$TRAEFIK_ENV" CF_DNS_API_TOKEN)" ]; then
        echo "  already set (stacks/traefik/.env)"
    else
        printf '%s\n' \
    '  Needs a Cloudflare API token for DNS-01 wildcard certs. Do this in the' \
    '  browser that just opened:' \
    '    1. Create a token using the "Edit zone DNS" template for your domain.' \
    '    2. Paste it below (entry is hidden). Leave empty to set it later.'
        open_url "https://dash.cloudflare.com/profile/api-tokens"
        printf '  CF_DNS_API_TOKEN (hidden): '
        read -rs token || token=""
        printf '\n'
        if [ -n "$token" ]; then
            set_var "$TRAEFIK_ENV" CF_DNS_API_TOKEN "$token"
            echo "  set"
        else
            echo "  skipped"
        fi
    fi
    echo

    CLOUDFLARED_ENV=stacks/cloudflared/.env

    echo "== CLOUDFLARE_TUNNEL_TOKEN =="
    if [ -n "$(get_var "$CLOUDFLARED_ENV" CLOUDFLARE_TUNNEL_TOKEN)" ]; then
        echo "  already set (stacks/cloudflared/.env)"
    else
        printf '%s\n' \
    '  Needs a Cloudflare Tunnel token for WAN ingress. Do this in the browser' \
    '  that just opened:' \
    '    1. Zero Trust -> Networks -> Tunnels -> create a tunnel (Type: Cloudflared).' \
    '    2. Copy its token and paste it below (entry is hidden). Leave empty to' \
    '       set it later.'
        open_url "https://one.dash.cloudflare.com"
        printf '  CLOUDFLARE_TUNNEL_TOKEN (hidden): '
        read -rs token || token=""
        printf '\n'
        if [ -n "$token" ]; then
            set_var "$CLOUDFLARED_ENV" CLOUDFLARE_TUNNEL_TOKEN "$token"
            echo "  set"
        else
            echo "  skipped"
        fi
    fi
    echo

    echo "done. Still edit by hand (DOMAIN, SUB_DOMAIN_*, CONFIG_DIR) in"
    echo "stacks/*/.env, then run 'just up'."

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

# Bring the whole stack up (ensures networks + config dirs exist first)
# Custom CONFIG_DIR? run `just dirs <path> [PUID PGID]` once first, then `just up`.
up: networks dirs
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

# Show the resolved compose config for one stack, e.g. `just config media-server`
config stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" config

# List running containers
ps:
    docker ps

# Bootstrap the Torrentio indexer definition into prowlarr's config dir from the
# Prowlarr-Indexers repo (see docs/indexers.md).
# Idempotent; re-run to re-install. Requires git + network; run on the server.
# Not the default CONFIG_DIR? pass it positionally: just bootstrap-torrentio /custom/path
bootstrap-torrentio CONFIG_DIR="/mnt/storage/docker/data":
    @TMP="$$(mktemp -d)" \
    && git clone --depth 1 --filter=blob:none https://github.com/dreulavelle/Prowlarr-Indexers "$$TMP" >/dev/null 2>&1 \
    && mkdir -p "{{ CONFIG_DIR }}/prowlarr/Definitions/Custom" \
    && cp "$$TMP/Custom/torrentio.yml" "{{ CONFIG_DIR }}/prowlarr/Definitions/Custom/torrentio.yml" \
    && rm -rf "$$TMP" \
    && echo "installed {{ CONFIG_DIR }}/prowlarr/Definitions/Custom/torrentio.yml"
    @docker compose -f stacks/media-server/compose.yaml restart prowlarr 2>/dev/null \
        || echo "note: prowlarr is not running, the definition will load on next just up"

# Pre-create + chown service config dirs (idempotent; also called by `just up`)
# CONFIG_DIR defaults to /mnt/storage/docker/data; override positionally: just dirs /custom/path
# No-op if the dirs already exist and ownership is already PUID:PGID.
dirs CONFIG_DIR="/mnt/storage/docker/data" PUID="1000" PGID="1000":
    mkdir -p "{{ CONFIG_DIR }}"/{jellyfin/config,seerr/config,radarr,sonarr,prowlarr,profilarr/config,bazarr/config,decypharr/configs,crowdsec/config,crowdsec/data}
    chown -R "{{ PUID }}":"{{ PGID }}" "{{ CONFIG_DIR }}"
