set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

stack_list := "traefik cloudflared media-server"
restic_image := "restic/restic:0.19.1"

# Show available recipes
default:
    just --list

# Full first-time setup: create each .env, then walk through every variable.
# Secrets are generated or prompted (hidden); everything else defaults to the
# example value (Enter = keep). Shared vars (DOMAIN, CONFIG_DIR) are synced
# across stacks. Browser pages are only opened after confirmation, and only in
# a GUI session. Safe to re-run — nothing is overwritten without consent.
init:
    #!/usr/bin/env bash
    set -euo pipefail

    TRAEFIK_ENV=stacks/traefik/.env
    CLOUDFLARED_ENV=stacks/cloudflared/.env
    MEDIA_ENV=stacks/media-server/.env
    ALL_ENVS=("$TRAEFIK_ENV" "$CLOUDFLARED_ENV" "$MEDIA_ENV")

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
        local esc                     # (temp file + mv: `sed -i` is not portable,
        esc=$(printf '%s' "$3" | sed -e 's/[&|\\]/\\&/g')   # BSD/macOS sed eats the
        sed "s|^$2=.*|$2=$esc|" "$1" > "$1.tmp" && mv "$1.tmp" "$1"   # next arg)
    }

    vars_defined_in() {   # echoes each .env that defines the given VAR
        local var="$1" f
        for f in "${ALL_ENVS[@]}"; do
            if [ -f "$f" ] && grep -q "^$var=" "$f"; then
                printf '%s\n' "$f"
            fi
        done
    }

    set_all() {   # sets VAR to VALUE in every .env that defines it
        local var="$1" value="$2" f
        for f in $(vars_defined_in "$var"); do
            set_var "$f" "$var" "$value"
        done
    }

    is_gui() {   # true when a display server (or macOS) is available
        [ -n "${DISPLAY:-}" ] && return 0
        [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
        case "$(uname -s)" in
            Darwin) return 0 ;;
        esac
        return 1
    }

    show_or_open_url() {   # GUI: confirm first, then open. No GUI: print URL.
        local url="$1" yn
        if ! is_gui; then
            echo "  -> open in a browser: $url"
            return 0
        fi
        printf '  Open the page in your browser? [Y/n] '
        read -r yn || yn=""
        printf '\n'
        case "$yn" in
            ''|y|Y|yes|Yes|YES)
                if command -v xdg-open >/dev/null 2>&1; then
                    xdg-open "$url" >/dev/null 2>&1 &
                    disown || true
                elif command -v open >/dev/null 2>&1; then
                    open "$url" >/dev/null 2>&1 &
                    disown || true
                else
                    echo "  -> open in a browser: $url"
                fi
                ;;
            *) echo "  -> open in a browser: $url" ;;
        esac
    }

    prompt_value() {   # FILE VAR [hint] [normalizer]: show current value, Enter keeps, type to
        local file="$1" var="$2" hint="${3:-}" norm="${4:-}" cur ans
        cur=$(get_var "$file" "$var") || true
        if [ -n "$cur" ]; then
            printf '  %s [%s, Enter to keep] > ' "$var" "$cur"
        elif [ -n "$hint" ]; then
            printf '  %s [%s] > ' "$var" "$hint"
        else
            printf '  %s > ' "$var"
        fi
        read -r ans || ans=""
        if [ -n "$ans" ]; then
            if [ -n "$norm" ]; then
                ans=$("$norm" "$ans") || true
            fi
            if [ "$ans" != "$cur" ]; then
                set_all "$var" "$ans"
            fi
        fi
    }

    prompt_default() {   # FILE VAR DEFAULT: like prompt_value but an empty value offers
        local file="$1" var="$2" def="$3" cur ans   # DEFAULT on Enter instead of staying empty
        cur=$(get_var "$file" "$var") || true
        if [ -n "$cur" ]; then
            printf '  %s [%s, Enter to keep] > ' "$var" "$cur"
            read -r ans || ans=""
        else
            printf '  %s [%s, Enter to use] > ' "$var" "$def"
            read -r ans || ans=""
            [ -z "$ans" ] && ans="$def"
        fi
        if [ -n "$ans" ] && [ "$ans" != "$cur" ]; then
            set_var "$file" "$var" "$ans"
        fi
        return 0
    }

    abs_path() {   # print $1 as an absolute path, resolving relative against $PWD
        case "$1" in
            /*) p="$1" ;;
            *) p="$PWD/$1" ;;
        esac
        if command -v realpath >/dev/null 2>&1; then
            realpath -m "$p"
        else
            printf '%s\n' "$p"
        fi
    }

    prompt_id() {   # FILE VAR DEFAULT: propose DEFAULT (this user's id) while the value is
        local file="$1" var="$2" def="$3" cur ans   # unset or still the example 1000
        cur=$(get_var "$file" "$var") || true
        if [ "$cur" = "1000" ] || [ -z "$cur" ]; then
            printf '  %s [%s, Enter to use] > ' "$var" "$def"
            read -r ans || ans=""
            if [ -z "$ans" ]; then
                ans="$def"
            fi
        else
            printf '  %s [%s, Enter to keep] > ' "$var" "$cur"
            read -r ans || ans=""
        fi
        if [ -n "$ans" ] && [ "$ans" != "$cur" ]; then
            set_var "$file" "$var" "$ans"
        fi
        return 0
    }

    # CONFIG_DIR is derived, not configured: it is always the repo's own data/ dir.
    # The tracked traefik config, the app state and the restic backup scope all live
    # there, so pointing it elsewhere would silently split them apart.
    CONFIG_DIR_VALUE="$(abs_path "{{ justfile_directory() }}/data")"
    echo "== Config directory =="
    echo "  $CONFIG_DIR_VALUE (fixed - app configs, acme.json and traefik's config live here)"
    set_all CONFIG_DIR "$CONFIG_DIR_VALUE"
    echo

    echo "== Domain and paths (shared across stacks) =="
    prompt_value "$TRAEFIK_ENV" DOMAIN "your domain, e.g. example.com"
    echo

    echo "== traefik =="
    prompt_value "$TRAEFIK_ENV" SUB_DOMAIN_TRAEFIK
    # Let's Encrypt only needs a syntactically valid contact on a real domain - it stopped
    # sending mail in June 2025 and no longer stores the address, so it does not have to be
    # deliverable. It cannot be a dummy either: Boulder rejects @example.com outright.
    # Defaulting to admin@$DOMAIN is always valid (they own the zone) and needs no thought.
    printf '%s\n' \
        "  ACME_EMAIL is the Let's Encrypt contact address. It does not have to receive mail" \
        '  (they stopped sending it in 2025), but it must be a real domain - @example.com is' \
        '  rejected by their API - so it defaults to admin@ your own domain.'
    prompt_default "$TRAEFIK_ENV" ACME_EMAIL "admin@$(get_var "$TRAEFIK_ENV" DOMAIN)"
    echo

    echo "CROWDSEC_BOUNCER_API_KEY"
    if [ -n "$(get_var "$TRAEFIK_ENV" CROWDSEC_BOUNCER_API_KEY)" ]; then
        echo "  already set (stacks/traefik/.env)"
    else
        set_var "$TRAEFIK_ENV" CROWDSEC_BOUNCER_API_KEY "$(openssl rand -hex 32)"
        echo "  generated a random 32-byte key"
    fi
    echo

    echo "TRAEFIK_DASHBOARD_CREDENTIALS"
    if [ -n "$(get_var "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_CREDENTIALS)" ]; then
        echo "  already set (stacks/traefik/.env)"
    else
        echo "  htpasswd-style user:hash for the Traefik dashboard (blank password = generate nothing, username defaults to admin)."
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

    echo "CLOUDFLARE_DNS_TOKEN"
    dns_domain="$(get_var "$TRAEFIK_ENV" DOMAIN)"
    [ -n "$dns_domain" ] || dns_domain="<DOMAIN>"
    if [ -n "$(get_var "$TRAEFIK_ENV" CLOUDFLARE_DNS_TOKEN)" ]; then
        echo "  already set (stacks/traefik/.env): $dns_domain - Zone:Read, DNS:Edit"
    else
        printf '%s\n' \
    '  Needs a Cloudflare API token for DNS-01 wildcard certs.' \
    '  Create it (dash.cloudflare.com -> My Profile -> API Tokens ->' \
    '    Create Custom Token), mirroring the dashboard values:' \
    '    Permissions:' \
    '      Zone -> Zone -> Read' \
    '      Zone -> DNS -> Edit' \
    '    Zone Resources:' \
    '      Include -> Specific zone -> <DOMAIN>' \
    '    Client IP Address Filtering:' \
    '      skip - your ISP can change your public IP and break renewals' \
    '      (see docs/quickstart.md)' \
    '    TTL: optional' \
    '  Paste it below (hidden). Leave empty to skip; set it later.'
        show_or_open_url "https://dash.cloudflare.com/profile/api-tokens"
        printf '  CLOUDFLARE_DNS_TOKEN (hidden): '
        read -rs token || token=""
        printf '\n'
        if [ -n "$token" ]; then
            set_var "$TRAEFIK_ENV" CLOUDFLARE_DNS_TOKEN "$token"
            echo "  set: $dns_domain - Zone:Read, DNS:Edit"
            echo "  verifying with Cloudflare..."
            if command -v curl >/dev/null 2>&1 && \
               curl -fsS --connect-timeout 10 --max-time 20 \
                    "https://api.cloudflare.com/client/v4/user/tokens/verify" \
                    -H "Authorization: Bearer $token" | grep -q '"status":"active"'; then
                echo "  verified: token is active"
            else
                echo "  WARNING: could not verify the token (offline, wrong paste, or revoked)."
                echo "           This only checks validity - permissions surface at first cert issuance."
            fi
        else
            echo "  skipped"
        fi
    fi
    echo

    echo "== cloudflared =="
    echo "CLOUDFLARE_TUNNEL_TOKEN"
    if [ -n "$(get_var "$CLOUDFLARED_ENV" CLOUDFLARE_TUNNEL_TOKEN)" ]; then
        echo "  already set (stacks/cloudflared/.env)"
    else
        printf '%s\n' \
    '  Needs a Cloudflare Tunnel token for WAN ingress.' \
    '    1. one.dash.cloudflare.com -> Zero Trust -> Networks -> Tunnels' \
    '    2. Create a tunnel (Type: Cloudflared) and copy its token.' \
    '    3. Paste it below (hidden). Leave empty to skip; set it later.'
        show_or_open_url "https://one.dash.cloudflare.com"
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

    echo "== media-server =="
    sid=$(id -u); sgid=$(id -g)
    if [ "$sid" -eq 0 ]; then
        sid=1000; sgid=1000
        echo "  (running as root - proposing 1000:1000 so containers don't run as root;"
        echo "   re-run as your deploy user to use its uid/gid)"
    fi
    prompt_id "$MEDIA_ENV" ENV_PUID "$sid"
    prompt_id "$MEDIA_ENV" ENV_PGID "$sgid"
    echo
    for sub in JELLYFIN SEERR RADARR SONARR PROWLARR PROFILARR BAZARR DECYPHARR; do
        prompt_value "$MEDIA_ENV" "SUB_DOMAIN_$sub"
    done
    echo

    echo "== restic backups (optional) =="
    BACKUP_ENV=.env.restic
    if [ ! -f "$BACKUP_ENV" ]; then
        cp .env.restic.example .env.restic
        echo "created $BACKUP_ENV from .env.restic.example"
    fi
    if [ -n "$(get_var "$BACKUP_ENV" RESTIC_REPOSITORY)" ] && [ -n "$(get_var "$BACKUP_ENV" RESTIC_PASSWORD)" ]; then
        echo "  already configured ($(get_var "$BACKUP_ENV" RESTIC_REPOSITORY))"
    else
        printf '%s\n' \
    '  Back up this repo (all .env files + data/) to an encrypted restic repository in' \
    '  Cloudflare R2 (this stack lives on Cloudflare). Restic runs in a container; the' \
    '  values below come from dash.cloudflare.com -> R2 (Create bucket, then Manage R2' \
    '  API Tokens). Want a different backend? Edit RESTIC_REPOSITORY + creds in' \
    "  .env.restic - that's the only supported deviation."
        printf '  Configure R2 restic backups now? [y/N] '
        read -r yes_backup || yes_backup=""
        case "$yes_backup" in
        y|Y|yes|Yes|YES)
            cur_act=$(get_var "$BACKUP_ENV" R2_ACCOUNT_ID) || true
            if [ -n "$cur_act" ]; then
                printf '  R2 Account ID [%s, Enter to keep] > ' "$cur_act"
            else
                printf '  R2 Account ID (R2 dashboard, top of page) > '
            fi
            read -r acct || acct=""
            [ -n "$acct" ] && set_var "$BACKUP_ENV" R2_ACCOUNT_ID "$acct"

            cur_bkt=$(get_var "$BACKUP_ENV" R2_BUCKET) || true
            if [ -n "$cur_bkt" ]; then
                printf '  R2 bucket name [%s, Enter to keep] > ' "$cur_bkt"
            else
                printf '  R2 bucket name (R2 dashboard -> Create bucket) > '
            fi
            read -r bkt || bkt=""
            [ -n "$bkt" ] && set_var "$BACKUP_ENV" R2_BUCKET "$bkt"

            cur_key=$(get_var "$BACKUP_ENV" AWS_ACCESS_KEY_ID) || true
            if [ -n "$cur_key" ]; then
                printf '  R2 Access Key ID [%s, Enter to keep] > ' "$cur_key"
            else
                printf '  R2 Access Key ID (Manage R2 API Tokens) > '
            fi
            read -r akey || akey=""
            [ -n "$akey" ] && set_var "$BACKUP_ENV" AWS_ACCESS_KEY_ID "$akey"

            if [ -n "$(get_var "$BACKUP_ENV" AWS_SECRET_ACCESS_KEY)" ]; then
                printf '  R2 Secret Access Key [hidden, Enter to keep] > '
            else
                printf '  R2 Secret Access Key (hidden, same page) > '
            fi
            read -rs skey || skey=""
            printf '\n'
            [ -n "$skey" ] && set_var "$BACKUP_ENV" AWS_SECRET_ACCESS_KEY "$skey"

            acct=$(get_var "$BACKUP_ENV" R2_ACCOUNT_ID) || true
            bkt=$(get_var "$BACKUP_ENV" R2_BUCKET) || true
            if [ -n "$acct" ] && [ -n "$bkt" ]; then
                set_var "$BACKUP_ENV" AWS_DEFAULT_REGION auto
                set_var "$BACKUP_ENV" RESTIC_REPOSITORY "s3:https://$acct.r2.cloudflarestorage.com/$bkt"
            fi

            printf '  RESTIC_PASSWORD (hidden, blank to skip) > '
            read -rs rpw || rpw=""
            printf '\n'
            [ -n "$rpw" ] && set_var "$BACKUP_ENV" RESTIC_PASSWORD "$rpw"
            if [ -n "$(get_var "$BACKUP_ENV" RESTIC_REPOSITORY)" ] && [ -n "$(get_var "$BACKUP_ENV" RESTIC_PASSWORD)" ]; then
                echo "  restic configured (R2) - next: 'just backup-init', then 'just backup'."
            else
                echo "  left incomplete - fill RESTIC_REPOSITORY + RESTIC_PASSWORD in .env.restic later."
            fi
            ;;
        *) echo "  skipped - fill .env.restic later and run 'just backup-init'." ;;
        esac
    fi
    echo

    echo "done. Review stacks/*/.env, then run 'just up'."

# Create the shared Docker networks (idempotent)
networks:
    docker network inspect internal >/dev/null 2>&1 || docker network create internal
    docker network inspect external >/dev/null 2>&1 || docker network create external

# Validate every compose file against the docker compose schema.
# Read-only: never creates or edits a .env (compose treats .env as optional and the
# shell environment outranks it, so CONFIG_DIR is supplied here just for the check).
validate:
    @for s in {{ stack_list }}; do \
        echo "-- stacks/$s/compose.yaml" \
        && CONFIG_DIR="${CONFIG_DIR:-/tmp/just-validate}" \
           docker compose -f "stacks/$s/compose.yaml" config -q || exit 1 \
    ; done

# Pull fresh images for every stack
pull:
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" pull || exit 1 \
    ; done

# Update all containers to the images referenced in compose (pull + recreate changed ones)
update-all:
    just pull
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" up -d || exit 1 \
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
# `just dirs` reads CONFIG_DIR from stacks/media-server/.env; override with `just dirs <path> [PUID PGID]`.
up: networks dirs
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" up -d || exit 1 \
    ; done

# Tear the whole stack down
down:
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" down || exit 1 \
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
# CONFIG_DIR is read from stacks/media-server/.env (fallback the repo's data/ dir).
bootstrap-torrentio:
    #!/usr/bin/env bash
    set -euo pipefail

    CONFIG_DIR=$(sed -n 's|^CONFIG_DIR=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    CONFIG_DIR="${CONFIG_DIR:-{{ justfile_directory() }}/data}"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    git clone --depth 1 --filter=blob:none https://github.com/dreulavelle/Prowlarr-Indexers "$TMP" >/dev/null 2>&1
    mkdir -p "$CONFIG_DIR/prowlarr/Definitions/Custom"
    cp "$TMP/Custom/torrentio.yml" "$CONFIG_DIR/prowlarr/Definitions/Custom/torrentio.yml"
    echo "installed $CONFIG_DIR/prowlarr/Definitions/Custom/torrentio.yml"
    docker compose -f stacks/media-server/compose.yaml restart prowlarr 2>/dev/null \
        || echo "note: prowlarr is not running, the definition will load on next just up"

# Print a wiring cheat sheet for the *arrs: probes intra-stack reachability and
# reads each app's API key from $CONFIG_DIR so you can paste the right values
# into every UI (docs/arrs.md has the full walkthrough). Read-only; run on the
# server. CONFIG_DIR is taken from stacks/media-server/.env (custom via
# `just init`); override positionally: just wiring /custom/path
wiring CONFIG_DIR="":
    #!/usr/bin/env bash
    set -uo pipefail

    if [ -n "{{ CONFIG_DIR }}" ]; then
        CONFIG_DIR="{{ CONFIG_DIR }}"
    else
        CONFIG_DIR=$(sed -n 's|^CONFIG_DIR=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
        CONFIG_DIR="${CONFIG_DIR:-{{ justfile_directory() }}/data}"
    fi
    echo "config dir: $CONFIG_DIR"
    echo

    CS=stacks/media-server/compose.yaml
    TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 5"
    PING_SRC=""
    for c in sonarr radarr prowlarr bazarr; do
        if $TO docker compose -f "$CS" exec -T "$c" true >/dev/null 2>&1; then
            PING_SRC=$c
            break
        fi
    done

    echo "== intra-network reachability =="
    echo "(pinged from $PING_SRC; FAIL means the peer is not running or still starting)"
    if [ -z "$PING_SRC" ]; then
        echo "  no running exec source (sonarr/radarr/prowlarr/bazarr all down) - start the stack, then re-run"
    else
        for p in jellyfin:8096 seerr:5055 radarr:7878 sonarr:8989 prowlarr:9696 profilarr:6868 bazarr:6767 decypharr:8282; do
            if $TO docker compose -f "$CS" exec -T "$PING_SRC" bash -c "exec 3<>/dev/tcp/$p" >/dev/null 2>&1; then
                printf '  ok    %s\n' "$p"
            else
                printf '  FAIL  %s\n' "$p"
            fi
        done
    fi

    arr_key() {   # $1 = app name; echoes the ApiKey from its config.xml
        local f="$CONFIG_DIR/$1/config.xml"
        if [ ! -f "$f" ]; then
            echo "(no $1/config.xml - start $1 once so it writes its config)"
            return 1
        fi
        awk -F'[<>]' '
            /<ApiKey>/ {
                s=$0; sub(/^.*<ApiKey>/,"",s); sub(/<\/ApiKey>.*$/,"",s)
                gsub(/^[ \t]+|[ \t]+$/,"",s)
                if (s) { print s; exit }
                if (getline > 0) { sub(/^[ \t]+|[ \t]+$/,"",$0); print; exit }
            }' "$f" || true
    }

    dcy_token() {   # echoes decypharr's api_token from its config.json
        local f="$CONFIG_DIR/decypharr/configs/config.json"
        if [ ! -f "$f" ]; then
            echo "(no decypharr/configs/config.json - run the decypharr wizard first)"
            return 1
        fi
        local t
        t=$(sed -n 's/.*"api_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | tail -n1)
        if [ -z "$t" ]; then
            echo "(no api_token yet - finish decypharr auth setup)"
            return 1
        fi
        echo "$t"
    }

    SONARR_KEY=$(arr_key sonarr)
    RADARR_KEY=$(arr_key radarr)
    PROWLARR_KEY=$(arr_key prowlarr)
    DCY_TOKEN=$(dcy_token)

    echo
    echo "== API keys (read from $CONFIG_DIR) =="
    printf '  sonarr      %s\n' "$SONARR_KEY"
    printf '  radarr      %s\n' "$RADARR_KEY"
    printf '  prowlarr    %s\n' "$PROWLARR_KEY"
    case "$DCY_TOKEN" in
        "(no"*) printf '  decypharr   %s\n' "$DCY_TOKEN" ;;
        *) printf '  decypharr   %s  (Settings -> Auth; regenerate via POST /api/refresh-token)\n' "$DCY_TOKEN" ;;
    esac

    echo
    echo "== prowlarr -> Settings -> Apps (indexer sync) =="
    printf '  Sonarr  url http://sonarr:8989  api key %s\n' "$SONARR_KEY"
    printf '  Radarr  url http://radarr:7878  api key %s\n' "$RADARR_KEY"

    echo
    echo "== sonarr -> Settings -> Download Clients: add BOTH (debrid + usenet) =="
    echo "  qBittorrent  'Decypharr (debrid)': host decypharr port 8282"
    printf '    username http://sonarr:8989\n    password %s\n    category sonarr  priority 0\n' "$SONARR_KEY"
    echo "  SABnzbd      'Decypharr (usenet)': host decypharr port 8282 urlbase /sabnzbd"
    printf '    username http://sonarr:8989\n    password %s\n    category sonarr  priority 0\n' "$SONARR_KEY"
    echo "  (same keys for both; different priorities pick debrid vs usenet)"
    echo
    echo "== radarr -> Settings -> Download Clients: add BOTH (debrid + usenet) =="
    echo "  qBittorrent  'Decypharr (debrid)': host decypharr port 8282"
    printf '    username http://radarr:7878\n    password %s\n    category radarr  priority 0\n' "$RADARR_KEY"
    echo "  SABnzbd      'Decypharr (usenet)': host decypharr port 8282 urlbase /sabnzbd"
    printf '    username http://radarr:7878\n    password %s\n    category radarr  priority 0\n' "$RADARR_KEY"

    echo
    echo "== decypharr -> Settings -> Arrs (outbound / queue cleanup) =="
    printf '  Sonarr  host http://sonarr:8989  token %s\n' "$SONARR_KEY"
    printf '  Radarr  host http://radarr:7878  token %s\n' "$RADARR_KEY"

    echo
    echo "== bazarr -> Settings -> Sonarr / Radarr =="
    printf '  http://sonarr:8989  %s\n' "$SONARR_KEY"
    printf '  http://radarr:7878  %s\n' "$RADARR_KEY"

    echo
    echo "== profilarr -> Settings -> connections (add Sonarr/Radarr) =="
    printf '  http://sonarr:8989  %s\n' "$SONARR_KEY"
    printf '  http://radarr:7878  %s\n' "$RADARR_KEY"

    echo
    echo "== seerr -> Settings =="
    echo "  jellyfin  http://jellyfin:8096  + an API key created in Jellyfin Dashboard -> API Keys"
    printf '  radarr    http://radarr:7878  %s\n' "$RADARR_KEY"
    printf '  sonarr    http://sonarr:8989  %s\n' "$SONARR_KEY"

    echo
    echo "done. Paste URL + key pairs from the sections above; test each connection in the UI."

# Print a ready-to-paste hosts-file block for the LAN setup stage
# (docs/lan-access.md). Reads DOMAIN and every SUB_DOMAIN_* from
# the stack .env files and maps them all to the server's primary LAN IP (the "src"
# on its default route; hostname -I as a fallback). Override the address positionally
# to generate for another machine: just hosts 10.0.0.5. Read-only — copy the block
# into /etc/hosts (macOS/Linux) or C:\Windows\System32\drivers\etc\hosts (Windows).
hosts IP="auto":
    #!/usr/bin/env bash
    set -uo pipefail

    DOMAIN=$(sed -n 's|^DOMAIN=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    if [ -z "$DOMAIN" ]; then
        echo "no DOMAIN found in stacks/media-server/.env - run 'just init' first" >&2
        exit 1
    fi

    SUBS=$(
        for f in stacks/media-server/.env stacks/traefik/.env; do
            [ -f "$f" ] && sed -n 's|^SUB_DOMAIN_[A-Z0-9_]*=\([^[:space:]]*\).*|\1|p' "$f"
        done | sort -u | grep -v '^$' || true
    )
    if [ -z "$SUBS" ]; then
        echo "no SUB_DOMAIN_* values found - run 'just init' first" >&2
        exit 1
    fi

    if [ "{{ IP }}" = "auto" ]; then
        IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)
        if [ -z "$IP" ]; then
            IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        fi
    else
        IP="{{ IP }}"
    fi
    if [ -z "$IP" ]; then
        echo "could not detect the server's LAN IP - pass it positionally: just hosts <IP>" >&2
        exit 1
    fi

    HOSTS="$IP"
    while IFS= read -r sub; do
        HOSTS="$HOSTS $sub.$DOMAIN"
    done <<< "$SUBS"

    echo "# kickstArrt hostnames block (docs/lan-access.md)"
    echo "# edit: /etc/hosts (macOS/Linux, admin) | C:\\Windows\\System32\\drivers\\etc\\hosts (Windows)"
    echo "$HOSTS"
    echo "# flush: macOS  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    echo "#         Windows ipconfig /flushdns | Linux systemctl restart systemd-resolved"

# Encrypted, deduplicated repo backups with restic, run in a container (nothing to
# install). Documented backend is Cloudflare R2 (see how-to in the wiki); `.env.restic`
# is configured by `just init` (R2_ACCOUNT_ID / R2_BUCKET / AWS creds -> RESTIC_REPOSITORY
# + RESTIC_PASSWORD; `AWS_DEFAULT_REGION=auto` is required for R2). Deviating is one edit
# in .env.restic - RESTIC_REPOSITORY selects any backend (local, sftp:, s3:, b2:, rclone: ...)
# and RESTIC_PASSWORD encrypts it; everything in that file is forwarded via docker run
# --env-file, so backend credentials added there are forwarded too. Scope: the repo working
# tree - every .env plus data/ (with the default layout that includes the $CONFIG_DIR app
# config state too). If you point CONFIG_DIR at external storage, cover it with native
# snapshots / a second restic profile. Configure .env.restic with `just init`, or copy
# .env.restic.example by hand.
[group('Backups')]
backup-init:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f .env.restic ]; then
        echo "no .env.restic - run 'just init' (answer yes to restic) or copy .env.restic.example to .env.restic"
        exit 1
    fi
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    if docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} snapshots >/dev/null 2>&1; then
        echo "repository already initialized at $(sed -n 's|^RESTIC_REPOSITORY=\(.*\)|\1|p' .env.restic | tail -n1)"
    else
        echo "initializing restic repository ..."
        docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} init
    fi

[group('Backups')]
backup:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        -v "{{ justfile_directory() }}":/repo:ro \
        {{ restic_image }} backup /repo \
        --exclude /repo/.git

[group('Backups')]
backup-list:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} snapshots

[group('Backups')]
backup-check:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} check

[group('Backups')]
backup-prune:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    KEEP_ARGS=()
    while IFS= read -r line; do
        [[ "$line" =~ ^RESTIC_KEEP_([A-Z]+)=([0-9]+)$ ]] || continue
        [ "${BASH_REMATCH[2]}" -gt 0 ] || continue
        KEEP_ARGS+=( "--keep-${BASH_REMATCH[1],,}" "${BASH_REMATCH[2]}" )
    done < .env.restic

    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        {{ restic_image }} forget --prune "${KEEP_ARGS[@]}"

# Restore a snapshot into the repo working tree (default: latest). Non-destructive:
# dry-runs first and shows exactly what would change, then asks before writing.
# Files not in the snapshot are kept (no --delete); restored files replace current
# ones in place (restic --overwrite=always).
[group('Backups')]
backup-restore SNAPSHOT="latest":
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    echo "previewing what the restore would change (dry run; nothing is written) ..."
    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        -v "{{ justfile_directory() }}":/repo:ro \
        {{ restic_image }} restore "{{ SNAPSHOT }}" --target / --dry-run -vv

    echo
    printf 'Files not in the snapshot are kept; the rest get overwritten in place. Restore %s into %s/? ' "{{ SNAPSHOT }}" "{{ justfile_directory() }}"
    read -r confirm || confirm=""
    case "$confirm" in
    y|Y|yes|Yes|YES) : ;;
    *) echo "aborted - nothing was restored."; exit 1 ;;
    esac

    echo
    echo "restoring {{ SNAPSHOT }} into {{ justfile_directory() }}/ ..."
    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        -v "{{ justfile_directory() }}":/repo \
        {{ restic_image }} restore "{{ SNAPSHOT }}" --target /

# Install a systemd timer that runs 'just backup' on ON_CALENDAR (default daily).
# Writes kickstarrt-restic-backup.{service,timer} under /etc/systemd/system via sudo, then
# enables the timer. Rerun to change the schedule. systemd is assumed on Linux
# servers; on a host without it (Alpine, a NAS scheduler, cron) this prints a
# fallback instead of erroring, and .env.restic is required before it will run.
[group('Backups')]
backup-schedule ON_CALENDAR="daily":
    #!/usr/bin/env bash
    set -euo pipefail

    command -v systemctl >/dev/null 2>&1 || {
        echo "no systemd (systemctl not found) - run the backup via cron instead, e.g.:"
        echo "  0 4 * * * cd '{{ justfile_directory() }}' && $(command -v just || echo 'just') backup"
        echo "(or your NAS scheduler; see docs/maintenance.md)"
        exit 1
    }
    command -v sudo >/dev/null 2>&1 || { echo "sudo not found - install sudo or run these commands as root"; exit 1; }
    command -v just >/dev/null 2>&1 || { echo "'just' not on PATH - install just before scheduling"; exit 1; }
    [ -f .env.restic ] || { echo "no .env.restic - configure restic first ('just init' or copy .env.restic.example)"; exit 1; }

    JUST_BIN=$(command -v just)
    REPO="{{ justfile_directory() }}"
    ON_CALENDAR="{{ ON_CALENDAR }}"

    printf '%s\n' \
        "This installs a systemd timer that runs '$JUST_BIN backup' in '$REPO'" \
        "on calendar '$ON_CALENDAR'. Two files are written under /etc/systemd/system" \
        'with sudo and the timer is enabled + started:'
    printf '  /etc/systemd/system/kickstarrt-restic-backup.timer\n  /etc/systemd/system/kickstarrt-restic-backup.service\n'
    printf 'Proceed? [y/N] '
    read -r ok || ok=""
    case "$ok" in
    y|Y|yes|Yes|YES) : ;;
    *) echo "aborted"; exit 1 ;;
    esac

    printf '%s\n' \
        '[Unit]' \
        'Description=Restic backup of the media repo' \
        'After=network-online.target' \
        'Wants=network-online.target' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        "WorkingDirectory=$REPO" \
        "ExecStart=$JUST_BIN backup" \
        | sudo tee /etc/systemd/system/kickstarrt-restic-backup.service >/dev/null

    printf '%s\n' \
        '[Unit]' \
        'Description=Run the restic repo backup daily' \
        '' \
        '[Timer]' \
        "OnCalendar=$ON_CALENDAR" \
        'Persistent=true' \
        'Unit=kickstarrt-restic-backup.service' \
        '' \
        '[Install]' \
        'WantedBy=timers.target' \
        | sudo tee /etc/systemd/system/kickstarrt-restic-backup.timer >/dev/null

    sudo systemctl daemon-reload
    sudo systemctl enable --now kickstarrt-restic-backup.timer
    echo
    echo "installed kickstarrt-restic-backup.{service,timer} - timer enabled and active."
    systemctl list-timers kickstarrt-restic-backup.timer --no-pager
    echo "remove it later with 'just backup-unschedule'."

# Stop and remove the restic backup systemd timer + service installed by
# backup-schedule (idempotent; sudo)
[group('Backups')]
backup-unschedule:
    #!/usr/bin/env bash
    set -euo pipefail

    command -v systemctl >/dev/null 2>&1 || { echo "no systemd - nothing to uninstall"; exit 0; }
    command -v sudo >/dev/null 2>&1 || { echo "sudo not found - run these commands as root"; exit 1; }

    sudo systemctl disable --now kickstarrt-restic-backup.timer >/dev/null 2>&1 || true
    sudo systemctl reset-failed kickstarrt-restic-backup.timer >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/kickstarrt-restic-backup.timer /etc/systemd/system/kickstarrt-restic-backup.service
    sudo systemctl daemon-reload
    echo "removed kickstarrt-restic-backup.{timer,service} and stopped the timer."

# Prepare everything on disk that compose bind-mounts (idempotent; called by `just up`):
# the per-service config dirs, traefik's logs dir and acme.json (0600, must be a FILE -
# docker would otherwise create a directory and ACME storage breaks), and the rendered
# traefik.yml. CONFIG_DIR comes from stacks/media-server/.env (the repo's data/ dir).
# PUID/PGID default to "auto": media-server .env ENV_PUID/ENV_PGID, else this user's
# ids, else 1000 - so ownership always matches what the containers run as.
# Override positionally: just dirs /custom/path 1000 1000
dirs CONFIG_DIR="" PUID="auto" PGID="auto":
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -n "{{ CONFIG_DIR }}" ]; then
        CONFIG_DIR="{{ CONFIG_DIR }}"
    else
        CONFIG_DIR=$(sed -n 's|^CONFIG_DIR=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
        CONFIG_DIR="${CONFIG_DIR:-{{ justfile_directory() }}/data}"
    fi
    PUID="{{ PUID }}"
    PGID="{{ PGID }}"
    [ "$PUID" = auto ] && PUID=$(sed -n 's|^ENV_PUID=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    [ "$PGID" = auto ] && PGID=$(sed -n 's|^ENV_PGID=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    if [ "$PUID" = auto ] || [ -z "$PUID" ]; then
        PUID=$(id -u)
        [ "$PUID" -eq 0 ] && PUID=1000
    fi
    if [ "$PGID" = auto ] || [ -z "$PGID" ]; then
        PGID=$(id -g)
        [ "$PGID" -eq 0 ] && PGID=1000
    fi
    mkdir -p "$CONFIG_DIR"/{jellyfin/config,seerr/config,radarr,sonarr,prowlarr,profilarr/config,bazarr/config,decypharr/configs,crowdsec/config,crowdsec/data}

    # traefik: logs dir (crowdsec reads it) + acme.json as a FILE with 0600, or
    # docker creates a directory there and cert storage silently fails.
    mkdir -p "$CONFIG_DIR/traefik/logs"
    [ -e "$CONFIG_DIR/traefik/acme.json" ] || touch "$CONFIG_DIR/traefik/acme.json"
    chmod 600 "$CONFIG_DIR/traefik/acme.json" 2>/dev/null || true

    # traefik's static config cannot read env vars, so render it here.
    TPL="{{ justfile_directory() }}/data/traefik/traefik.template.yml"
    if [ -f "$TPL" ]; then
        ACME_EMAIL=$(sed -n 's|^ACME_EMAIL=\(.*\)|\1|p' stacks/traefik/.env 2>/dev/null | tail -n1 || true)
        ACME_EMAIL="${ACME_EMAIL:-}"
        sed "s|\${ACME_EMAIL}|$ACME_EMAIL|g" "$TPL" > "$CONFIG_DIR/traefik/traefik.yml.tmp"
        mv "$CONFIG_DIR/traefik/traefik.yml.tmp" "$CONFIG_DIR/traefik/traefik.yml"
        if [ -z "$ACME_EMAIL" ]; then
            echo "warning: ACME_EMAIL is empty in stacks/traefik/.env - traefik requires it for"
            echo "         the ACME resolver, so no certificates will be issued. Run 'just init'."
            echo "         (There is no Let's Encrypt account to sign up for - see docs/ingress.md.)"
        fi
    fi

    # Only touch entries that are actually mis-owned, and never abort `just up`
    # over a file we cannot chown (e.g. root-owned state from a container).
    chown "$PUID":"$PGID" "$CONFIG_DIR" 2>/dev/null || true
    find "$CONFIG_DIR" \( ! -uid "$PUID" -o ! -gid "$PGID" \) -exec chown "$PUID":"$PGID" {} + 2>/dev/null || true
