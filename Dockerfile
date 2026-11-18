# The image holds only the static binary zig cross-compiles; nothing is built inside it.
#   zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix dist/linux-amd64
#   docker build -t easyrelay .
# For arm64, build aarch64-linux-musl into dist/linux-arm64 and pass --platform linux/arm64.
FROM scratch
ARG TARGETARCH
COPY dist/linux-${TARGETARCH}/bin/easyrelay /usr/local/bin/easyrelay
ENV EASYRELAY_NETWORK_ADDRESS=0.0.0.0 \
    EASYRELAY_STORAGE_PATH=/var/lib/easyrelay
VOLUME /var/lib/easyrelay
WORKDIR /etc/easyrelay
EXPOSE 7777
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/easyrelay"]
