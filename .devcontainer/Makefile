.PHONY: dc.shell dc.up dc.build dc.claude dc.restart dc.down

# Open a shell inside the devcontainer
dc.shell:
	devcontainer exec --workspace-folder . zsh

# Start the devcontainer
dc.up:
	devcontainer up --workspace-folder .

# Rebuild the devcontainer
dc.build:
	devcontainer up --workspace-folder . --build-no-cache

# Run Claude Code inside the devcontainer (skip permissions)
dc.claude:
	claude --dangerously-skip-permissions

# Stop and restart the devcontainer
dc.restart:
	docker restart $$(docker ps -qf "label=devcontainer.local_folder=$(CURDIR)") && devcontainer up --workspace-folder .

# Stop and remove the devcontainer
dc.down:
	docker rm -f $$(docker ps -aqf "label=devcontainer.local_folder=$(CURDIR)")
