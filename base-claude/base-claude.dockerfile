FROM docker.io/docker/sandbox-templates:claude-code

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
