FROM alpine:3.22

ARG XRAY_VERSION=v26.3.27
ARG TARGETARCH

RUN apk add --no-cache bash ca-certificates curl jq libqrencode-tools openssl unzip \
    && case "${TARGETARCH}" in \
        amd64) xray_arch="64" ;; \
        arm64) xray_arch="arm64-v8a" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${xray_arch}.zip" \
    && unzip /tmp/xray.zip xray geoip.dat geosite.dat -d /tmp/xray \
    && mkdir -p /usr/local/share/xray \
    && install -m 0755 /tmp/xray/xray /usr/local/bin/xray \
    && install -m 0644 /tmp/xray/geoip.dat /usr/local/share/xray/geoip.dat \
    && install -m 0644 /tmp/xray/geosite.dat /usr/local/share/xray/geosite.dat \
    && rm -rf /tmp/xray /tmp/xray.zip

COPY docker/xray-config /usr/local/bin/xray-config
COPY docker/tool /usr/local/bin/tool
COPY docker/entrypoint /usr/local/bin/docker-entrypoint

RUN chmod 0755 /usr/local/bin/xray-config /usr/local/bin/tool /usr/local/bin/docker-entrypoint \
    && mkdir -p /etc/xray /var/lib/xray/users

VOLUME ["/var/lib/xray"]
EXPOSE 443/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD test -s /run/xray.pid && kill -0 "$(cat /run/xray.pid)"

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
