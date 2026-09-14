# Agent RAG local. CPU ONLY -- fara GPU, fara CUDA, fara nimic grafic.
# Aceeasi imagine merge si pe laptop si pe server.

# ---------------------------------------------------------------- 1. build
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp .

# Build PORTABIL, nu "native".
# Un binar compilat cu -march=native pe Ryzen-ul tau poate crapa sau merge
# prost pe procesorul serverului. Cu GGML_CPU_ALL_VARIANTS, llama.cpp compileaza
# mai multe variante de backend (sandybridge, haswell, zen4, sapphirerapids...)
# si alege singur, la pornire, pe care o poate rula masina pe care se afla.
RUN set -eux; \
    if cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
         -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
         -DBUILD_SHARED_LIBS=ON -DLLAMA_CURL=OFF \
         -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF; then \
      echo "build portabil cu variante multiple de CPU"; \
    else \
      echo "llama.cpp nu stie variante multiple aici, trec pe baseline"; \
      rm -rf build; \
      cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF \
        -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF; \
    fi; \
    cmake --build build --target llama-server -j "$(nproc)"

# Binarul si bibliotecile stau in ACELASI folder: asa isi gaseste singur
# backend-urile de CPU incarcate dinamic.
# "cp -a" pastreaza legaturile simbolice si numele versionate (libX.so.0).
# Fara ele binarul nu porneste, desi fisierele par sa fie toate acolo.
RUN set -eux; \
    mkdir -p /out; \
    cp -a build/bin/. /out/; \
    find build -name '*.so*' -exec cp -a {} /out/ ';' ; \
    rm -rf /out/CMakeFiles; \
    ls -1 /out

# ---------------------------------------------------------------- 2. runtime
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=utf-8

# pdftotext pentru PDF-uri, tesseract pentru cele scanate (ro + ru + en),
# Nimic grafic, nimic legat de GPU.
#
# numpy NU e instalat, intentionat: cautarea pe cuvinte (cea implicita)
# nu-l foloseste, iar pachetul ocupa 37 MB. E necesar doar pentru
# cautarea semantica, care oricum ar cere si un al doilea server.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        poppler-utils \
        tesseract-ocr tesseract-ocr-ron tesseract-ocr-rus tesseract-ocr-eng \
        curl ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ /opt/llama/
ENV PATH="/opt/llama:${PATH}" \
    LD_LIBRARY_PATH="/opt/llama"

COPY bin/agent.py bin/ingest.py /app/
COPY docker/entrypoint-agent.sh /app/
RUN chmod +x /app/entrypoint-agent.sh

ENV AGENT_HOME=/agent \
    DATA_DIR=/agent/data \
    DOCS_DIRS=/docs \
    USE_EMBEDDINGS=0 \
    LLM_URL=http://llm:8080

RUN mkdir -p /agent/data /docs
WORKDIR /app

# Verificare la build. Daca binarul nu porneste aici, imaginea NU se face.
# Mai bine pica acum, cu mesaj clar, decat pe server peste doua zile.
RUN set -eux; \
    llama-server --version 2>&1 | head -3; \
    python3 -c "import json, re, urllib.request"; \
    command -v pdftotext; \
    command -v tesseract
