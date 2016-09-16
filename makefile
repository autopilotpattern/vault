MAKEFLAGS += --warn-undefined-variables
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail
.DEFAULT_GOAL := build

TAG?=latest

# run the Docker build
build:
	docker build -t="autopilotpattern/vault:${TAG}" .

# push our image to the public registry
ship:
	docker tag autopilotpattern/vault:${TAG} autopilotpattern/vault:latest
	docker push "autopilotpattern/vault:${TAG}"
	docker push "autopilotpattern/vault:latest"
