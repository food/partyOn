FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 make git ca-certificates python3 python3-pip binutils-mingw-w64-x86-64 xxd \
 && pip3 install --break-system-packages capstone pefile \
 && git clone --depth 1 https://github.com/TsudaKageyu/minhook /opt/minhook \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
