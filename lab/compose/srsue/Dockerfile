# srsUE (srsRAN 4G) with the ZeroMQ radio, built from the commit pinned in
# versions.yaml. Two stages: compile, then a small runtime image.

FROM ubuntu:22.04 AS build
ARG SRSRAN_4G_COMMIT=6bcbd9e5bf8686aa7085202cd847c5ddd64a9c16
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates \
      libfftw3-dev libmbedtls-dev libboost-program-options-dev \
      libconfig++-dev libsctp-dev libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/srsran/srsRAN_4G.git /src \
    && git -C /src checkout ${SRSRAN_4G_COMMIT}
RUN cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_ZEROMQ=ON -DENABLE_RF_PLUGINS=OFF \
      -DENABLE_UHD=OFF -DENABLE_BLADERF=OFF -DENABLE_SOAPYSDR=OFF \
      -DENABLE_GUI=OFF \
    && cmake --build /build --target srsue -j"$(nproc)"

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      libfftw3-single3 libmbedcrypto7 libboost-program-options1.74.0 \
      libconfig++9v5 libsctp1 libzmq5 \
      iproute2 iputils-ping curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/srsue/src/srsue /usr/local/bin/srsue
# Fail the build now (not at runtime) if a shared library is missing
RUN if ldd /usr/local/bin/srsue | grep -q "not found"; then ldd /usr/local/bin/srsue; exit 1; fi
