# syntax = docker/dockerfile:1.4

### >>> TEMPORARY FOR LOCAL DEV (REPLACE WITH BASE IMAGE TAG WHEN FINISHED) >>>
ARG UBUNTU_IMAGE=ubuntu:26.04
### <<< END TEMPORARY FOR LOCAL DEV <<<
ARG GIT_COMMIT_HASH="unknown"

# --- Builder Stage ---
FROM ${UBUNTU_IMAGE} AS builder

LABEL org.opencontainers.image.source="https://github.com/dbca-wa/wildlifelicensing"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Australia/Perth \
    PRODUCTION_EMAIL=False \
    SECRET_KEY="ThisisNotRealKey" \
    NOTIFICATION_EMAIL="asi@dbca.wa.gov.au" \
    NON_PROD_EMAIL="asi@dbca.wa.gov.au" \
    EMAIL_INSTANCE="UAT" \
    OSCAR_SHOP_NAME="Parks & Wildlife" \
    BPAY_ALLOWED=False

### >>> TEMPORARY FOR LOCAL DEV (REMOVE WHEN USING OFFICIAL BASE IMAGE) >>>
# Update mirror list for Ubuntu 26.04 (deb822 format)
RUN sed -i 's|archive.ubuntu.com|au.archive.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources || true

# Install build dependencies, GIS libraries, and generic python3 packages
RUN --mount=type=cache,target=/var/cache/apt apt-get update && \
    apt-get upgrade -y && \
    apt-get install --no-install-recommends -y \
    build-essential \
    ca-certificates \
    curl \
    git \
    gcc \
    gdal-bin \
    libgdal-dev \
    libgeos-dev \
    libproj-dev \
    libpq-dev \
    libxml2-dev \
    libxslt1-dev \
    python3 \
    python3-venv \
    python3-pip \
    python3-dev \
    patch \
    tzdata \
    wget \
    gnupg && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js 24 from NodeSource and global utilities
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
    | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    npm install -g handlebars && \
    rm -rf /var/lib/apt/lists/*
### <<< END TEMPORARY FOR LOCAL DEV <<<

# Create app user early so files can be chown'd during copy
RUN groupadd -g 5000 oim && useradd -g 5000 -u 5000 -s /bin/bash -d /app oim && mkdir -p /app && chown oim:oim /app

WORKDIR /app
USER oim

# Copy only what's needed for pip install (keep .git out)
COPY --chown=oim:oim requirements.txt gunicorn.ini.py manage.py python-cron ./
COPY --chown=oim:oim wildlifelicensing ./wildlifelicensing
COPY --chown=oim:oim startup.sh /

# Create venv and install python deps as the unprivileged user using standard python3
ENV VIRTUAL_ENV=/app/venv
ENV PATH=$VIRTUAL_ENV/bin:$PATH
RUN python3 -m venv $VIRTUAL_ENV && \
    $VIRTUAL_ENV/bin/pip install --upgrade pip setuptools wheel && \
    $VIRTUAL_ENV/bin/pip install --no-cache-dir -r requirements.txt

# Collect static (still in builder stage)
RUN touch /app/.env
RUN $VIRTUAL_ENV/bin/python manage.py collectstatic --noinput

# --- Runtime Stage ---
FROM ${UBUNTU_IMAGE} AS runtime

ARG GIT_COMMIT_HASH

ENV GIT_COMMIT_HASH=$GIT_COMMIT_HASH
ENV TZ=Australia/Perth

LABEL org.opencontainers.image.revision=$GIT_COMMIT_HASH
LABEL com.azure.dev.image.build.sourceversion=$GIT_COMMIT_HASH

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Set runtime environment defaults (can be overridden at container start)
ENV PRODUCTION_EMAIL=False \
    SECRET_KEY="ThisisNotRealKey" \
    NOTIFICATION_EMAIL="asi@dbca.wa.gov.au" \
    NON_PROD_EMAIL="asi@dbca.wa.gov.au" \
    EMAIL_INSTANCE="UAT" \
    OSCAR_SHOP_NAME="Parks & Wildlife" \
    BPAY_ALLOWED=False

### >>> TEMPORARY FOR LOCAL DEV (REMOVE WHEN USING OFFICIAL BASE IMAGE) >>>
# Install runtime libraries required by Python wheels (GIS, PostgreSQL, XML)
RUN apt-get update && apt-get upgrade -y && apt-get install --no-install-recommends -y \
    ca-certificates \
    tzdata \
    wget \
    python3 \
    python3-venv \
    gdal-bin \
    libgdal-dev \
    libpq-dev \
    libxml2 \
    libxslt1.1 \
    openssl \
 && apt-get install --only-upgrade -y openssl ca-certificates \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install standard utility scripts (installs /bin/scheduler.py, etc.)
RUN wget https://raw.githubusercontent.com/dbca-wa/wagov_utils/main/wagov_utils/bin/default_script_installer.sh -O /tmp/default_script_installer.sh && \
    chmod 755 /tmp/default_script_installer.sh && \
    /tmp/default_script_installer.sh && \
    rm -rf /tmp/*
### <<< END TEMPORARY FOR LOCAL DEV <<<

# Create non-root user to run the app
RUN groupadd -g 5000 oim && useradd -g 5000 -u 5000 -s /bin/bash -d /app oim && mkdir -p /app && chown oim:oim /app

USER oim
WORKDIR /app

# Copy only runtime artifacts from builder
COPY --from=builder --chown=oim:oim /app/venv /app/venv
COPY --from=builder --chown=oim:oim /app/wildlifelicensing /app/wildlifelicensing
COPY --from=builder --chown=oim:oim /app/gunicorn.ini.py /app/gunicorn.ini.py
COPY --from=builder --chown=oim:oim /app/manage.py /app/manage.py
COPY --from=builder --chown=oim:oim /app/.env /app/.env
COPY --from=builder --chown=oim:oim /app/staticfiles_wl /app/staticfiles_wl
COPY --from=builder --chown=oim:oim /app/python-cron /app/python-cron

# Copy startup script and ensure executable
COPY --from=builder --chown=oim:oim /startup.sh /startup.sh
RUN chmod 0755 /startup.sh || true

ENV PATH=/app/venv/bin:$PATH

EXPOSE 8080
HEALTHCHECK --interval=1m --timeout=5s --start-period=10s --retries=3 CMD ["wget","-q","-O","-","http://localhost:8080/"]

CMD ["/bin/bash","/startup.sh"]