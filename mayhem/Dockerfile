# syntax=docker/dockerfile:1.7
# Commit-image Dockerfile (RUST / cargo-fuzz) for facebook/sapling eden dag fuzz targets.
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# edition 2024 in the sapling crates needs a recent nightly; -Zsanitizer=address needs nightly.
ARG RUST_CHANNEL=nightly-2025-08-01
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain "${RUST_CHANNEL}"; \
    rustup component add rust-src --toolchain "${RUST_CHANNEL}"; \
    cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked; \
    rm -f /tmp/rustup-init.sh; \
    chown -R 2000:2000 /opt/toolchains/rust; chmod -R a+rX /opt/toolchains/rust; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git"; chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    # DWARF<4 gate (SPEC 6.2 item 10): the prebuilt std rlibs (DWARF-4) and the clang-built sanitizer
    # runtime archives (DWARF-5) carry debug CUs that -Zdwarf-version cannot rewrite, so the linked
    # fuzz binary would inherit a DWARF>=4 first CU. Strip their debug info (rmeta/code preserved) so
    # only our own DWARF-3 CUs remain; Mayhem triage cannot read DWARF>=4.
    RLIBDIR="$RUSTUP_HOME/toolchains/${RUST_CHANNEL}-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib"; \
    for a in "$RLIBDIR"/*.rlib "$RLIBDIR"/librustc-nightly_rt.*.a; do [ -e "$a" ] && objcopy --strip-debug "$a" || true; done; \
    rustc --version; cargo --version; cargo fuzz --version

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
