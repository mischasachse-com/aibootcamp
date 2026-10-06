# Project Critical Orbit — dev container
# Base: Microsoft devcontainers Python image (3.12 on Debian Bookworm).
# Verify the tag is current before each delivery:
#   https://mcr.microsoft.com/v2/devcontainers/python/tags/list
FROM mcr.microsoft.com/devcontainers/python:1-3.12-bookworm

# CLI tooling used throughout the labs:
#   jq          — JSON parsing in scripts/*.sh
#   shellcheck  — linting for the shell scripts (also used by CI)
# The base image ships an expired yarnpkg apt key; drop that repo before update.
RUN rm -f /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends jq shellcheck \
    && rm -rf /var/lib/apt/lists/*

# Bicep CLI is installed via `az bicep install` in postCreateCommand
# (devcontainer.json) so it always matches the installed Azure CLI version.
