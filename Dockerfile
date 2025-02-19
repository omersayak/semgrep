###############################################################################
# Overview
###############################################################################
# First, we build a fully *static* 'semgrep-core' binary on Alpine. This
# binary does not even depend on Glibc because Alpine uses Musl instead
# which can be statically linked.
#
# Then 'semgrep-core' alone is copied to another Alpine-based container
# which takes care of the 'semgrep-cli' (a.k.a. pysemgrep) Python wrapping.
#
# We use Alpine because it allows to generate the smallest Docker images.
# We use this two-steps process because *building* semgrep-core itself
# requires lots of tools (ocamlc, gcc, make, etc.), with big containers,
# but those tools are not necessary when *running* semgrep.
# This is a standard practice in the Docker world.
# See https://docs.docker.com/build/building/multi-stage/

###############################################################################
# Step0: collect files needed to build semgrep-cpre
###############################################################################

# The semgrep git repository contains the source code to multiple build artifacts
# (semgrep, semgrep-core, semgrep.js, etc...). In order to maximize Docker cache
# hits (and keep the build fast), we only copy over the folders needed to build
# semgrep-core. This is done in a multi-stage build so that the final COPY
# happens in a single layer.

FROM busybox:stable as semgrep-core-files
WORKDIR /src/semgrep

# copy over the entire semgrep repository
COPY . .

# remove files and folders that aren't necessary for the semgrep-core build
# coupling: see the (dirs ...) directive in the toplevel dune file for the list
# of directories containing OCaml code and which should not be added below
# (except js/ which contains OCaml code but is not used to build semgrep-core)
RUN rm -rf cli js .github .circleci Dockerfile

# we *do* need the cli's semgrep_interfaces folder, however
COPY cli/src/semgrep/semgrep_interfaces cli/src/semgrep/semgrep_interfaces

###############################################################################
# Step1: build semgrep-core
###############################################################################

# The Docker image below (after the 'FROM') is prepackaged with 'ocamlc',
# 'opam', and lots of packages that are used by semgrep-core and installed in
# the 'make install-deps' command further below.
# See https://github.com/returntocorp/ocaml-layer/blob/master/configs/alpine.sh
# for this list of packages.
# Thanks to this container, 'make install-deps' finishes very quickly because it's
# mostly a noop. Alternative base container candidates are:
#
#  - 'ocaml/opam:alpine', the official OCaml/opam Docker image,
#    but building our Docker image would take longer because
#    of all the necessary Semgrep dependencies installed in 'make install-deps'.
#
#    We build a new Semgrep Docker image on each pull-request (PR) so we don't
#    want to wait 30min each time just for 'docker build' to finish.
#
#    Note also that ocaml/opam:alpine default user is 'opam', not 'root', which
#    is not without problems when used inside Github actions (GHA) or even inside
#    this Dockerfile.
#
#    update: we recently started to cache the ~/.opam/ directory in CI so
#    in theory we could get rid of ocaml-layer and instead use the official
#    opam docker image combined with this ~/.opam/ caching to speedup things.
#
#  - 'alpine', the official Alpine Docker image, but this would require some
#    extra 'apk' commands to install opam, and extra commands to setup OCaml
#    with this opam from scratch, and more importantly this would take
#    far more time to finish. Moreover, it is not trivial to work from such
#    a base container as 'opam' itself requires lots of extra
#    tools like gcc, make, which are not provided by default on Alpine.
#
# An alternative to ocaml-layer would be to use https://depot.dev/
# update: we actually started to use depot.dev to speedup multi-arch (arm)
# docker image, so maybe we could use it to get rid of ocaml-layer
#
# Note that the Docker base image below currently uses OCaml 4.14.0
# coupling: if you modify the OCaml version there, you probably also need
# to modify:
# - scripts/{osx-setup-for-release,setup-m1-builder}.sh
# - doc/SEMGREP_CORE_CONTRIBUTING.md
# - https://github.com/Homebrew/homebrew-core/blob/master/Formula/semgrep.rb
#
# coupling: if you modify the FROM below, you probably need to modify also
# a few .github/workflows/ files. grep for returntocorp/ocaml there.

# This base image should be updated regularly to maximize the caching
# of opam packages. We don't use a rolling ':latest' tag to ensure
# reproducible builds and fix problems more easily.
#
# Visit https://hub.docker.com/r/returntocorp/ocaml/tags to see the latest
# images available.
#
FROM returntocorp/ocaml:alpine-2023-10-17 as semgrep-core-container

WORKDIR /src/semgrep
COPY --from=semgrep-core-files /src/semgrep .

#TODO: update the root image to include python 3.9 so the apk commands
# run internally in make 'install-deps-alpine-xxx' below are fast too
RUN make install-deps-ALPINE-for-semgrep-core &&\
    make install-deps-for-semgrep-core

# Let's build just semgrep-core
WORKDIR /src/semgrep
# An alternative to the eval is to use 'opam exec -- ...'
RUN eval "$(opam env)" &&\
    make minimal-build &&\
    # Sanity check
    /src/semgrep/_build/default/src/main/Main.exe -version

###############################################################################
# Step2: Build the semgrep Python wheel
###############################################################################
# This is an intermediary stage used for building Python wheels. Semgrep users
# don't need to use this.
FROM python:3.11-alpine AS semgrep-wheel

WORKDIR /semgrep

# Install some deps (build-base because ruamel.yaml has native code)
#
# libffi-dev is needed for installing Python dependencies in
# scripts/build-wheels.sh on arm64
RUN apk add --no-cache build-base zip bash libffi-dev

# Copy in the CLI
COPY cli ./cli

# Copy in semgrep-core executable
COPY --from=semgrep-core-container /src/semgrep/_build/default/src/main/Main.exe cli/src/semgrep/bin/semgrep-core

# Copy in scripts folder
COPY scripts/ ./scripts/

# Build the source distribution and binary wheel, validate that the wheel installs correctly
# We're only checking the musllinux wheel because this is an Alpine container. It shouldnt be a problem because the content of the wheels are identical.
RUN scripts/build-wheels.sh && scripts/validate-wheel.sh cli/dist/*musllinux*.whl

###############################################################################
# Step3: Build the final docker image with Python wrapper and semgrep-core bin
###############################################################################
# We change container, bringing the 'semgrep-core' binary with us.

#coupling: the 'semgrep-oss' name is used in 'make build-docker'
FROM python:3.11.4-alpine AS semgrep-oss

WORKDIR /semgrep

# Update to the latest packages for the base image.
# This allows to get CVE fixes ASAP, without waiting for new builds of the base image.
# See docker-library/python#761 for an example of such an issue in the past
# where the time between the CVE was discovered and the package update was X days, but
# the new base image was updated only after Y days.
RUN apk upgrade --no-cache && \
# Here is why we need the apk packages below:
# - git, git-lfs, openssh: so that the semgrep docker image can be used in
#   Github actions (GHA) and get git submodules and use ssh to get those submodules
# - bash, curl, jq: various utilities useful in CI jobs (e.g., our benchmark jobs,
#   which needs to use the latest semgrep docker image, also need a few utilities called
#   in some of our bash and python scripts/)
#   alt: we used to have an alternate semgrep-dev.Dockerfile container to use
#   for our benchmarks, but it complicates things and the addition of those
#   packages do not add much to the size of the docker image (<1%).
    apk add --no-cache --virtual=.run-deps\
    git git-lfs openssh\
    bash curl jq

# We just need the Python code in cli/.
# The semgrep-core stuff would be copied from the other container
COPY cli ./

#???
ENV PIP_DISABLE_PIP_VERSION_CHECK=true \
    PIP_NO_CACHE_DIR=true \
    PYTHONIOENCODING=utf8 \
    PYTHONUNBUFFERED=1

# Let's now simply use 'pip' to install semgrep.
# Note the difference between .run-deps and .build-deps below.
# We use a single command to install packages, install semgrep, and remove
# packages to keep a small Docker image (classic Docker trick).
# Here is why we need the apk packages below:
#  - build-base: ??
# hadolint ignore=DL3013
RUN apk add --no-cache --virtual=.build-deps build-base make &&\
     pip install /semgrep &&\
     apk del .build-deps

# Let the user know how their container was built
COPY Dockerfile /Dockerfile

# Get semgrep-core from step1
COPY --from=semgrep-core-container /src/semgrep/_build/default/src/main/Main.exe /usr/local/bin/semgrep-core

RUN ln -s semgrep-core /usr/local/bin/osemgrep

# There are a few places in the CLI where we do different things
# depending on whether we are run from a Docker container.
# See also Semgrep_envvars.ml and Metrics_.mli.
ENV SEMGREP_IN_DOCKER=1 \
    SEMGREP_USER_AGENT_APPEND="Docker"

# The command we tell people to run for testing semgrep in Docker is
#   docker run --rm -v "${PWD}:/src" returntocorp/semgrep semgrep --config=auto
# (see https://semgrep.dev/docs/getting-started/ ), hence the WORKDIR directive below
WORKDIR /src

# Better to avoid running semgrep as root
# See https://stackoverflow.com/questions/49193283/why-it-is-unsafe-to-run-applications-as-root-in-docker-container
# Note though that the actual USER directive is done in Step 4.
RUN adduser -D -u 1000 -h /home/semgrep semgrep \
    && chown semgrep /src

# Disabling defaulting to the user semgrep for now
# We can set it by default once we fix the circle ci workflows
# See nonroot build stage below.
#USER semgrep

# Workaround for rootless containers as git operations may fail due to dubious
# ownership of /src
RUN printf "[safe]\n	directory = /src"  > ~root/.gitconfig
RUN printf "[safe]\n	directory = /src"  > ~semgrep/.gitconfig && \
	chown semgrep:semgrep ~semgrep/.gitconfig


# In case of problems, if you need to debug the docker image, run 'docker build .',
# identify the SHA of the build image and run 'docker run -it <sha> /bin/bash'
# to interactively explore the docker image.
CMD ["semgrep", "--help"]
LABEL maintainer="support@semgrep.com"

###############################################################################
# Step4: install semgrep-pro
###############################################################################
# This step is valid only when run from Github Actions.
# See .github/workflows/build-test-docker.yaml

#coupling: the 'semgrep-cli' name is used in release.jsonnet
FROM semgrep-oss AS semgrep-cli

# A semgrep docker image with semgrep-pro already included in the image,
# to save time in CI as one does not need to wait 2min each time to
# download it.
RUN --mount=type=secret,id=SEMGREP_APP_TOKEN SEMGREP_APP_TOKEN=$(cat /run/secrets/SEMGREP_APP_TOKEN) semgrep install-semgrep-pro --debug

# Clear out any detritus from the pro install
RUN rm -rf /root/.semgrep

###############################################################################
# Step5: (optional) nonroot variant
###############################################################################

# Additional build stage that sets a non-root user.
# We can't make this the default in the semgrep-cli stage above because of
# permissions errors on the mounted volume when using instructions for running
# semgrep with docker:
# `docker run -v "${PWD}:/src" -i returntocorp/semgrep semgrep`
FROM semgrep-cli AS nonroot

# We need to move the core binary out of the protected /usr/local/bin dir so
# the non-root user can run `semgrep install-semgrep-pro` and use Pro Engine
# alt: we could also do this work directly in the root docker image.
# TODO? now that we install semgrep-pro in step4, do we still need that?
RUN rm /usr/local/bin/osemgrep && \
    mkdir /home/semgrep/bin && \
    mv /usr/local/bin/semgrep-core /home/semgrep/bin && \
    ln -s semgrep-core /home/semgrep/bin/osemgrep && \
    chown semgrep:semgrep /home/semgrep/bin

# Update PATH with new core binary location
ENV PATH="$PATH:/home/semgrep/bin"

USER semgrep

###############################################################################
# Step6: (optional) performance testing
###############################################################################

# Build target that exposes the performance benchmark tests in perf/ for
# use in running performance benchmarks from a test build container, e.g., on PRs
FROM semgrep-cli AS performance-tests

COPY perf /semgrep/perf

RUN apk add --no-cache make

WORKDIR /semgrep/perf

ENTRYPOINT ["make"]
