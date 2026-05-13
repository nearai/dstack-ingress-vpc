# nginx:1.29-bookworm (nginx 1.29.1) — current stable line with HTTP/3 / QUIC
# compiled in via --with-http_v3_module. Verified with:
#   docker run --rm <digest> nginx -V 2>&1 | grep http_v3
# Pinned by digest for reproducibility, same pattern as the previous pin.
# (The previous pin b6653fca was nginx 1.27.4-bookworm; bumping to the
# current stable line so we ship on a supported HTTP/3 implementation.)
FROM nginx@sha256:8adbdcb969e2676478ee2c7ad333956f0c8e0e4c5a7463f4611d7a2e7a7ff5dc

RUN --mount=type=bind,source=pinned-packages.txt,target=/tmp/pinned-packages.txt,ro \
    set -e; \
    # Create a sources.list file pointing to a specific snapshot.
    # Snapshot date is aligned with the nginx:1.29-bookworm image push date
    # (2025-09-30) so apt sees package versions consistent with the base image.
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250930T000000Z bookworm main' > /etc/apt/sources.list && \
    echo 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250930T000000Z bookworm-security main' >> /etc/apt/sources.list && \
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
    /var/log/nginx && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# Copy custom nginx configuration
COPY --chmod=644 nginx.conf /etc/nginx/nginx.conf

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
