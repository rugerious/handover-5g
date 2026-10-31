# OCUDU gNB with only the ZeroMQ radio (no UHD, no DPDK), for the lab.
#
# Why our own Dockerfile: in OCUDU's docker/Dockerfile (release_26_10) the
# "lean" target builds only the CU (no radio), and every gNB target compiles
# UHD and/or DPDK from source, which a ZMQ lab does not use. This follows
# OCUDU's recipe (its dependency script, gcc, Release, target "gnb") and
# switches those radios off. ROHC is optional in OCUDU and not built here.
#
# Build context: the OCUDU checkout at the commit pinned in versions.yaml.
#   docker buildx build --load -f lab/compose/gnb/Dockerfile \
#     -t handover/ocudu-gnb:release_26_10 /opt/handover/src/ocudu

ARG OS_VERSION=26.04

FROM ubuntu:${OS_VERSION} AS build
ARG MARCH=native
ENV DEBIAN_FRONTEND=noninteractive
COPY docker/scripts/ /src/docker/scripts/
RUN apt-get update \
    && /src/docker/scripts/install_dependencies.sh build \
    && rm -rf /var/lib/apt/lists/*
COPY . /src
RUN cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=False -DENABLE_UHD=Off -DENABLE_DPDK=Off -DENABLE_ZEROMQ=On \
      -DMARCH=${MARCH} \
    && cmake --build /src/build --target gnb -j"$(nproc)"

FROM ubuntu:${OS_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
COPY docker/scripts/ /tmp/scripts/
RUN apt-get update \
    && /tmp/scripts/install_dependencies.sh run \
    && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/* /tmp/scripts
COPY --from=build /src/build/apps/gnb/gnb /usr/local/bin/gnb
# Fail the build now, not at runtime: every library present, ZeroMQ linked in
RUN if ldd /usr/local/bin/gnb | grep -q "not found"; then ldd /usr/local/bin/gnb; exit 1; fi \
    && if ! ldd /usr/local/bin/gnb | grep -q libzmq; then echo "gnb built WITHOUT ZeroMQ" >&2; exit 1; fi
