.PHONY: list dc.up dc.status dc.stop dc.rebuild dc.rebuild.force dc.down dc.shell dc.claude dc.claude.update dc.makefile.pull dc.bun.install dc.tidewave dc.tidewave.bg dc.tidewave.stop dc.tidewave.update dc.logs.proxy dc.server dc.test dc.worktree.new dc.worktree.list dc.worktree.remove

define require_devcontainer
	@if [ "$$DEVCONTAINER" != "true" ]; then echo "Error: This command must be run inside the devcontainer." >&2; exit 1; fi
endef

list:
	@printf "  %-22s  %s\n" \
		"make list"              "List all available commmands (you ran this)" \
		"" "" \
		"# Commands to run inside your project" "" \
		"make dc.up"             "Start the devcontainer" \
		"make dc.status"         "Show whether the devcontainer is running" \
		"make dc.stop"           "Stop the devcontainer (keeps container)" \
		"make dc.rebuild"        "Rebuild and start the devcontainer" \
		"make dc.down"           "Stop and remove the devcontainer" \
		"make dc.shell"          "Open a shell inside the devcontainer" \
		"" "" \
		"# Commands to run inside the devcontainer" "" \
		"make dc.claude"         "Run Claude Code (with --dangerously-skip-permissions)" \
		"make dc.claude.update"  "Update Claude Code to the latest release" \
		"make dc.makefile.pull"  "Update this Makefile from the upstream devcontainer repo" \
		"make dc.bun.install"    "Installs the assets with bun" \
		"make dc.tidewave"       "Run Tidewave (exposed on localhost:9833)" \
		"make dc.tidewave.bg"    "Run Tidewave in the background" \
		"make dc.tidewave.stop"  "Stop background Tidewave" \
		"make dc.tidewave.update" "Update Tidewave CLI to the latest release" \
		"make dc.server"         "Starts the Phoenix server inside an IEx session" \
		"make dc.test"           "Runs the test suite using 'mix test'" \
		"make dc.logs.proxy"     "Print proxy logs" \
		"make dc.logs.tidewave"  "Print tidewave logs" \
		"" "" \
		"# Worktree commands (run inside the devcontainer)" "" \
		"make dc.worktree.new feature-x"      "Create worktree for branch feature-x (from HEAD)" \
		"make dc.worktree.new feature-x main" "Create worktree for branch feature-x (from main)" \
		"make dc.worktree.list"               "List all worktrees" \
		"make dc.worktree.remove x"           "Remove worktree x" \
		"wt feature-x"                        "Switch to git worktree feature-x" \
		"wt"                                  "Switch to main git worktree" \
		"" ""

dc.up:
	devcontainer up --workspace-folder .

dc.status:
	@id=$$(docker ps -qf "label=devcontainer.local_folder=$(CURDIR)"); \
	if [ -n "$$id" ]; then echo "Devcontainer is running ($$id)"; \
	else echo "Devcontainer is not running"; fi

dc.stop:
	@id=$$(docker ps -aqf "label=devcontainer.local_folder=$(CURDIR)"); \
	if [ -n "$$id" ]; then docker stop $$id; else echo "No devcontainer running"; fi

dc.rebuild:
	@$(MAKE) dc.down
	devcontainer up --workspace-folder .

dc.rebuild.force:
	@$(MAKE) dc.down
	devcontainer up --build-no-cache --workspace-folder .

dc.down:
	@id=$$(docker ps -aqf "label=devcontainer.local_folder=$(CURDIR)"); \
	if [ -n "$$id" ]; then docker rm -f $$id >/dev/null && echo "Devcontainer removed: $$id"; else echo "No devcontainer to remove"; fi
	@vol=$$(basename $(CURDIR))-node-modules; \
	if docker volume inspect $$vol >/dev/null 2>&1; then \
		docker volume rm $$vol >/dev/null && echo "Volume removed: $$vol"; \
	else echo "No volume to remove"; fi

dc.shell:
	exec devcontainer exec --workspace-folder . zsh

dc.claude:
	$(require_devcontainer)
	exec claude --dangerously-skip-permissions

dc.claude.update:
	$(require_devcontainer)
	@echo "Updating Claude Code to the latest release..."
	@npm install -g @anthropic-ai/claude-code@latest \
		&& echo "Claude Code updated: $$(claude --version 2>/dev/null || echo 'installed')"

dc.makefile.pull:
	@echo "Pulling latest Makefile from PJUllrich/devcontainer..."
	@curl -sL https://github.com/PJUllrich/devcontainer/archive/refs/heads/main.tar.gz \
		| tar xz --strip-components=2 devcontainer-main/.devcontainer/Makefile \
		&& echo "Makefile updated."

dc.bun.install:
	exec mix bun assets install

dc.tidewave:
	$(require_devcontainer)
	exec tidewave --allow-remote-access --allowed-origins http://localhost:9836

dc.tidewave.bg:
	@$(MAKE) dc.tidewave > /tmp/tidewave.log 2>&1 & echo "Tidewave started (pid $$!). Logs: /tmp/tidewave.log"

dc.tidewave.stop:
	$(require_devcontainer)
	@pkill -f tidewave && echo "Tidewave stopped" || echo "Tidewave is not running"

dc.tidewave.update:
	$(require_devcontainer)
	@ARCH=$$(uname -m); \
	case "$$ARCH" in \
		aarch64|arm64) ARCH=aarch64 ;; \
		x86_64|amd64)  ARCH=x86_64 ;; \
		*) echo "Unsupported architecture: $$ARCH" >&2; exit 1 ;; \
	esac; \
	echo "Downloading latest Tidewave CLI ($$ARCH)..."; \
	curl -fsSL -o $$HOME/.local/bin/tidewave \
		https://github.com/tidewave-ai/tidewave_app/releases/latest/download/tidewave-cli-$$ARCH-unknown-linux-gnu \
	&& chmod +x $$HOME/.local/bin/tidewave \
	&& echo "Tidewave updated: $$($$HOME/.local/bin/tidewave --version 2>/dev/null || echo 'installed')"

dc.logs.proxy:
	$(require_devcontainer)
	exec tail -f /var/log/squid/access.log

dc.logs.tidewave:
	$(require_devcontainer)
	exec tail -f /tmp/tidewave.log

dc.server:
	$(require_devcontainer)
	exec iex -S mix phx.server

dc.test:
	$(require_devcontainer)
	MIX_ENV=test mix test

# --- Worktree commands ---
# Usage: make dc.worktree.new <name> [base-branch]
# The extra args are consumed via MAKECMDGOALS so make doesn't treat them as targets.
dc.worktree.new:
	$(require_devcontainer)
	$(eval WT_NAME := $(word 2,$(MAKECMDGOALS)))
	$(eval WT_BASE := $(word 3,$(MAKECMDGOALS)))
	@if [ -z "$(WT_NAME)" ]; then echo "Usage: make dc.worktree.new <name> [base-branch]"; exit 1; fi
	@if [ -n "$(WT_BASE)" ]; then \
		git worktree add .worktrees/$(WT_NAME) -b $(WT_NAME) $(WT_BASE); \
	else \
		git worktree add .worktrees/$(WT_NAME) -b $(WT_NAME); \
	fi

dc.worktree.list:
	$(require_devcontainer)
	@git worktree list

# Usage: make dc.worktree.remove <name>
dc.worktree.remove:
	$(require_devcontainer)
	$(eval WT_NAME := $(word 2,$(MAKECMDGOALS)))
	@if [ -z "$(WT_NAME)" ]; then echo "Usage: make dc.worktree.remove <name>"; exit 1; fi
	git worktree remove .worktrees/$(WT_NAME)

# Catch positional args passed after worktree targets so make doesn't error
%:
	@:
