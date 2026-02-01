# Multi-stage Dockerfile for Slurm runtime
# Stage 1: Build RPMs using the builder image
# Stage 2: Install RPMs in a clean runtime image

ARG SLURM_VERSION

# ============================================================================
# Stage 1: Build RPMs
# ============================================================================
FROM rockylinux/rockylinux:9 AS builder

ARG SLURM_VERSION
ARG TARGETARCH

# Enable CRB and EPEL repositories for development packages
# Install RPM build tools and dependencies
RUN set -ex \
    && dnf makecache \
    && dnf -y update \
    && dnf -y install dnf-plugins-core epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf makecache \
    && dnf -y install \
       autoconf \
       automake \
       bzip2 \
       jansson-devel \
       libtool \
       freeipmi-devel \
       dbus-devel \
       gcc \
       gcc-c++ \
       git \
       gtk2-devel \
       hdf5-devel \
       http-parser-devel \
       hwloc-devel \
       json-c-devel \
       libcurl-devel \
       libyaml-devel \
       lua-devel \
       lz4-devel \
       make \
       man2html \
       mariadb-devel \
       munge \
       munge-devel \
       ncurses-devel \
       numactl-devel \
       openssl-devel \
       pam-devel \
       perl \
       python3 \
       python3-devel \
       readline-devel \
       rpm-build \
       rpmdevtools \
       rrdtool-devel \
       wget \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Setup RPM build environment
RUN rpmdev-setuptree

# Build and install libjwt so Slurm can be built with auth_jwt plugin (AuthAltTypes=auth/jwt)
# See https://slurm.schedmd.com/related_software.html#jwt (libjwt >= v1.10.0)
RUN set -ex \
    && git clone --depth 1 --single-branch -b v1.12.0 https://github.com/benmcollins/libjwt.git /tmp/libjwt \
    && cd /tmp/libjwt \
    && autoreconf --force --install \
    && ./configure --prefix=/usr/local \
    && make -j$(nproc) \
    && make install \
    && ldconfig \
    && (cp -n /usr/local/lib64/libjwt* /usr/local/lib/ 2>/dev/null || true) \
    && (cp -n /usr/local/lib/libjwt* /usr/local/lib64/ 2>/dev/null || true) \
    && rm -rf /tmp/libjwt

# Copy RPM macros
COPY rpmbuild/slurm.rpmmacros /root/.rpmmacros

# Download official Slurm release tarball and build RPMs with slurmrestd and JWT enabled
# libjwt must be installed so Slurm's configure enables auth_jwt; set PKG_CONFIG_PATH so rpmbuild finds it.
RUN set -ex \
    && RPM_ARCH=$(case "${TARGETARCH}" in \
         amd64) echo "x86_64" ;; \
         arm64) echo "aarch64" ;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
       esac) \
    && echo "Building Slurm RPMs for architecture: ${RPM_ARCH} (with JWT support)" \
    && wget -O /root/rpmbuild/SOURCES/slurm-${SLURM_VERSION}.tar.bz2 \
       https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2 \
    && cd /root/rpmbuild/SOURCES \
    && export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    && export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}" \
    && rpmbuild -ta slurm-${SLURM_VERSION}.tar.bz2 \
    && ls -lh /root/rpmbuild/RPMS/${RPM_ARCH}/

# ============================================================================
# Stage 2: Runtime image
# ============================================================================
FROM rockylinux/rockylinux:9

LABEL org.opencontainers.image.source="https://github.com/giovtorres/slurm-docker-cluster" \
      org.opencontainers.image.title="slurm-docker-cluster" \
      org.opencontainers.image.description="Slurm Docker cluster on Rocky Linux 9" \
      maintainer="Giovanni Torres"

ARG SLURM_VERSION
ARG TARGETARCH

# Enable CRB and EPEL repositories for runtime dependencies
RUN set -ex \
    && dnf makecache \
    && dnf -y update \
    && dnf -y install dnf-plugins-core epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf makecache

# Install runtime dependencies only (including golang for Go programs in slurmctld)
RUN set -ex \
    && dnf -y install \
       bash-completion \
       bzip2 \
       gettext \
       golang \
       hdf5 \
       http-parser \
       hwloc \
       jansson \
       json-c \
       jq \
       libaec \
       libyaml \
       lua \
       lz4 \
       mariadb \
       munge \
       numactl \
       perl \
       procps-ng \
       psmisc \
       python3 \
       readline \
       vim-enhanced \
       wget \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Install gosu for privilege dropping
ARG GOSU_VERSION=1.19

RUN set -ex \
    && echo "Installing gosu for architecture: ${TARGETARCH}" \
    && wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-${TARGETARCH}" \
    && wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-${TARGETARCH}.asc" \
    && export GNUPGHOME="$(mktemp -d)" \
    && gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 \
    && gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
    && rm -rf "${GNUPGHOME}" /usr/local/bin/gosu.asc \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true

COPY --from=builder /root/rpmbuild/RPMS/*/*.rpm /tmp/rpms/

# Copy libjwt from builder first so it is present before Slurm RPM install.
# Slurm RPMs were built with JWT support and require libjwt.so.0; we provide it
# from our build. Install Slurm with --nodeps so rpm does not require libjwt
# to be in the package database. Register /usr/local so the dynamic linker finds libjwt.
RUN mkdir -p /usr/local/lib64
COPY --from=builder /usr/local/lib64/libjwt* /usr/local/lib64/
RUN echo '/usr/local/lib64' > /etc/ld.so.conf.d/local.conf \
    && echo '/usr/local/lib' >> /etc/ld.so.conf.d/local.conf \
    && ldconfig

# Install Slurm RPMs (--nodeps: libjwt is already on disk above)
RUN set -ex \
    && rpm -Uvh --nodeps /tmp/rpms/slurm-[0-9]*.rpm \
       /tmp/rpms/slurm-perlapi-*.rpm \
       /tmp/rpms/slurm-slurmctld-*.rpm \
       /tmp/rpms/slurm-slurmd-*.rpm \
       /tmp/rpms/slurm-slurmdbd-*.rpm \
       /tmp/rpms/slurm-slurmrestd-*.rpm \
       /tmp/rpms/slurm-contribs-*.rpm \
    && rm -rf /tmp/rpms \
    && dnf clean all

# Install Singularity
RUN set -ex \
    && dnf -y install \
       apptainer \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Create slurm user and group. slurmrestd must NOT run with SlurmUser's group (slurm).
# Use a shared group slurmjwt so both slurm (slurmctld) and slurmrest (slurmrestd) can read the JWT key.
RUN set -x \
    && groupadd -r --gid=990 slurm \
    && useradd -r -g slurm --uid=990 slurm \
    && groupadd -r --gid=991 slurmrest \
    && useradd -r -g slurmrest --uid=991 slurmrest \
    && groupadd -r --gid=992 slurmjwt \
    && usermod -a -G slurmjwt slurm \
    && usermod -a -G slurmjwt slurmrest

# Fix /etc permissions and create munge key
RUN set -x \
    && chmod 0755 /etc \
    && /sbin/create-munge-key

# Create slurm dirs with correct ownership
RUN set -x \
    && mkdir -m 0755 -p \
        /var/run/slurm \
        /var/spool/slurm \
        /var/lib/slurm \
        /var/log/slurm \
        /etc/slurm \
    && chown slurm:slurm \
        /var/run/slurm \
        /var/spool/slurm \
        /var/lib/slurm \
        /var/log/slurm \
        /etc/slurm

# Copy Slurm configuration files
# Version-specific configs: Extract major.minor from SLURM_VERSION (e.g., "24.11" from "24.11.6")
COPY config/ /tmp/slurm-config/
RUN set -ex \
    && MAJOR_MINOR=$(echo ${SLURM_VERSION} | cut -d. -f1,2) \
    && echo "Detected Slurm version: ${MAJOR_MINOR}" \
    && if [ -f "/tmp/slurm-config/${MAJOR_MINOR}/slurm.conf" ]; then \
         echo "Using version-specific config for ${MAJOR_MINOR}"; \
         cp /tmp/slurm-config/${MAJOR_MINOR}/slurm.conf /etc/slurm/slurm.conf; \
       else \
         echo "No version-specific config found for ${MAJOR_MINOR}, using latest (25.05)"; \
         cp /tmp/slurm-config/25.05/slurm.conf /etc/slurm/slurm.conf; \
       fi \
    && cp /tmp/slurm-config/common/slurmdbd.conf /etc/slurm/slurmdbd.conf \
    && if [ -f "/tmp/slurm-config/${MAJOR_MINOR}/cgroup.conf" ]; then \
         echo "Using version-specific cgroup.conf for ${MAJOR_MINOR}"; \
         cp /tmp/slurm-config/${MAJOR_MINOR}/cgroup.conf /etc/slurm/cgroup.conf; \
       else \
         echo "Using common cgroup.conf"; \
         cp /tmp/slurm-config/common/cgroup.conf /etc/slurm/cgroup.conf; \
       fi \
    && chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf /etc/slurm/slurmdbd.conf \
    && chmod 644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf \
    && chmod 600 /etc/slurm/slurmdbd.conf \
    && rm -rf /tmp/slurm-config
COPY --chown=slurm:slurm --chmod=0600 examples /root/examples

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY init-jwt-key.sh /usr/local/bin/init-jwt-key.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/init-jwt-key.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

CMD ["slurmdbd"]
