FROM nginx@sha256:b6653fca400812e81569f9be762ae315db685bc30b12ddcdc8616c63a227d3ca

RUN --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    # Create a sources.list file pointing to a specific snapshot
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250411T024939Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250411T024939Z bookworm-security main' >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/10no-check-valid-until && \
    # Create preferences file to pin all packages
    rm -rf /etc/apt/sources.list.d/debian.sources && \
    mkdir -p /etc/apt/preferences.d && \
    cat /tmp/pinned-packages.txt | while read line; do \
        pkg=$(echo $line | cut -d= -f1); \
        ver=$(echo $line | cut -d= -f2); \
        if [ ! -z "$pkg" ] && [ ! -z "$ver" ]; then \
            echo "Package: $pkg\nPin: version $ver\nPin-Priority: 1001\n" >> /etc/apt/preferences.d/pinned-packages; \
        fi; \
    done && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        openssl \
        bash \
        python3-pip \
        python3-requests \
        python3.11 \
        python3.11-venv \
        curl \
        jq \
        coreutils && \
        rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/ldconfig/aux-cache

RUN mkdir -p \
    /etc/letsencrypt \
    /var/www/certbot \
    /usr/share/nginx/html \
    /etc/nginx/conf.d \
    /var/log/nginx

# Install scripts with deterministic permissions via bind mount
RUN --mount=type=bind,source=scripts,target=/tmp/scripts,ro \
    /bin/bash -o pipefail -c 'set -euo pipefail; \
        rm -rf /scripts && mkdir -p /scripts && chmod 755 /scripts && \
        cd /tmp/scripts && \
        find . -type d -print0 | while IFS= read -r -d "" dir; do \
            rel="${dir#./}"; \
            [[ -z "$rel" ]] && continue; \
            install -d -m 755 "/scripts/$rel"; \
        done && \
        find . -type f -print0 | while IFS= read -r -d "" file; do \
            rel="${file#./}"; \
            perm=644; \
            case "$rel" in \
                *.sh) perm=755 ;; \
                *.py) case "$rel" in */*) perm=644 ;; *) perm=755 ;; esac ;; \
            esac; \
            install -m "$perm" "$file" "/scripts/$rel"; \
        done'

ENV PATH="/scripts:$PATH"
ENV PYTHONPATH="/scripts"
COPY --chmod=664 .GIT_REV /etc/

ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
