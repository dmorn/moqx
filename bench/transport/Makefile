RELEASE_NAME ?= moqx_transport_bench
RELEASE_CLI ?= moqx-transport-bench
RELEASE_VERSION ?= $(shell sed -n 's/.*version: "\([^"]*\)".*/\1/p' mix.exs | head -1)
GIT_SHA ?= $(shell git -C ../.. rev-parse --short HEAD 2>/dev/null || echo unknown)

TARGET_OS ?= linux
TARGET_ARCH ?= arm64
DOCKER_PLATFORM ?= $(TARGET_OS)/$(TARGET_ARCH)
ELIXIR_IMAGE ?= elixir:1.19.5-otp-28

ARTIFACT_DIR ?= build/artifacts
ARTIFACT_NAME ?= $(RELEASE_CLI)-$(RELEASE_VERSION)-$(GIT_SHA)-$(TARGET_OS)-$(TARGET_ARCH).tar.gz
ARTIFACT ?= $(ARTIFACT_DIR)/$(ARTIFACT_NAME)

REMOTE_DIR ?= /opt/moqx-bench/moqx-transport-bench
SSH_OPTS ?=

.PHONY: help docker-release deploy-release clean

help:
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  docker-release   Build Linux release tarball with Docker buildx'
	@printf '%s\n' '  deploy-release   Copy release tarball to TARGETS and run remote help smoke'
	@printf '%s\n' '  clean            Remove local release artifacts'
	@printf '%s\n' ''
	@printf '%s\n' 'Examples:'
	@printf '%s\n' '  make docker-release'
	@printf '%s\n' '  make deploy-release TARGETS="root@203.0.113.10 root@203.0.113.11"'

docker-release:
	@mkdir -p "$(ARTIFACT_DIR)"
	docker buildx build \
		--platform "$(DOCKER_PLATFORM)" \
		--file docker/Dockerfile.release \
		--target artifact \
		--output "type=local,dest=$(ARTIFACT_DIR)" \
		--build-arg "ELIXIR_IMAGE=$(ELIXIR_IMAGE)" \
		--build-arg "RELEASE_NAME=$(RELEASE_NAME)" \
		--build-arg "ARTIFACT_NAME=$(ARTIFACT_NAME)" \
		../..
	@test -f "$(ARTIFACT)"
	@printf 'Built %s\n' "$(ARTIFACT)"

deploy-release:
	@test -n "$(TARGETS)" || (printf '%s\n' 'TARGETS is required, for example TARGETS="root@host-a root@host-b"' >&2; exit 2)
	@test -f "$(ARTIFACT)" || (printf 'Artifact not found: %s\nRun make docker-release first or pass ARTIFACT=/path/to/release.tar.gz\n' "$(ARTIFACT)" >&2; exit 2)
	SSH_OPTS="$(SSH_OPTS)" scripts/deploy_release.sh \
		--artifact "$(ARTIFACT)" \
		--remote-dir "$(REMOTE_DIR)" \
		--smoke \
		-- $(TARGETS)

clean:
	@rm -rf build
