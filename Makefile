PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
MISE ?= mise

PROJECTS := wrapper elixir
SMITHY_BIN := $(CURDIR)/wrapper/bin/smithy
SYMPHONY_BIN := $(CURDIR)/elixir/bin/symphony

.PHONY: help install uninstall clean test rebuild deploy check-mise check-runtimes trust deps build install-bin verify-install next-steps
.NOTPARALLEL:

help:
	@printf '%s\n' \
		'Targets:' \
		'  make install [PREFIX=~/.local]' \
		'  make uninstall [PREFIX=~/.local]' \
		'  make rebuild' \
		'  make deploy' \
		'  make clean' \
		'  make test'

install: check-mise
	@$(MAKE) trust
	@$(MAKE) check-runtimes
	@$(MAKE) deps
	@$(MAKE) build
	@$(MAKE) install-bin
	@$(MAKE) verify-install
	@$(MAKE) next-steps

uninstall:
	@for link_target in "smithy:$(SMITHY_BIN)" "symphony:$(SYMPHONY_BIN)"; do \
		name="$${link_target%%:*}"; \
		target="$${link_target#*:}"; \
		link="$(BINDIR)/$$name"; \
		if [ -L "$$link" ]; then \
			current="$$(readlink "$$link")"; \
			if [ "$$current" = "$$target" ]; then \
				rm -f "$$link"; \
				echo "removed $$link"; \
			else \
				echo "Refusing to remove $$link; it points at $$current, not $$target." >&2; \
				exit 1; \
			fi; \
		elif [ -e "$$link" ]; then \
			echo "Refusing to remove $$link; it is not a symlink created by this installer." >&2; \
			exit 1; \
		else \
			echo "$$link is already absent"; \
		fi; \
	done

clean: check-mise check-runtimes
	@for dir in $(PROJECTS); do \
		echo "==> $$dir: mix clean"; \
		(cd "$$dir" && "$(MISE)" exec -- mix clean); \
	done
	@rm -f "$(SMITHY_BIN)" "$(SYMPHONY_BIN)"

test: check-mise check-runtimes deps
	@test/install_makefile_test.sh
	@for dir in $(PROJECTS); do \
		echo "==> $$dir: mix test"; \
		(cd "$$dir" && "$(MISE)" exec -- mix test); \
	done

rebuild: check-mise check-runtimes
	@$(MAKE) build

deploy:
	@bash "$(CURDIR)/scripts/deploy.sh"

check-mise:
	@if ! command -v "$(MISE)" >/dev/null 2>&1; then \
		echo "mise is required but was not found." >&2; \
		echo "Install mise: https://mise.jdx.dev/getting-started.html" >&2; \
		echo "Then run: mise install" >&2; \
		exit 127; \
	fi

check-runtimes: check-mise
	@for dir in $(PROJECTS); do \
		if ! (cd "$$dir" && "$(MISE)" exec -- elixir --version >/dev/null 2>&1); then \
			echo "Erlang/Elixir runtimes are not available for $$dir." >&2; \
			echo "Run: cd $$dir && mise install" >&2; \
			exit 1; \
		fi; \
		if ! (cd "$$dir" && "$(MISE)" exec -- erl -eval 'halt().' -noshell >/dev/null 2>&1); then \
			echo "Erlang/Elixir runtimes are not available for $$dir." >&2; \
			echo "Run: cd $$dir && mise install" >&2; \
			exit 1; \
		fi; \
	done

trust: check-mise
	@for dir in $(PROJECTS); do \
		echo "==> $$dir: mise trust"; \
		(cd "$$dir" && "$(MISE)" trust); \
	done

deps: check-mise check-runtimes
	@for dir in $(PROJECTS); do \
		echo "==> $$dir: mix deps.get"; \
		(cd "$$dir" && "$(MISE)" exec -- mix deps.get); \
	done

build: check-mise check-runtimes
	@for dir in $(PROJECTS); do \
		echo "==> $$dir: mix escript.build"; \
		(cd "$$dir" && "$(MISE)" exec -- mix escript.build); \
	done

install-bin:
	@mkdir -p "$(BINDIR)"
	@ln -sfn "$(SMITHY_BIN)" "$(BINDIR)/smithy"
	@ln -sfn "$(SYMPHONY_BIN)" "$(BINDIR)/symphony"
	@echo "linked $(BINDIR)/smithy -> $(SMITHY_BIN)"
	@echo "linked $(BINDIR)/symphony -> $(SYMPHONY_BIN)"

verify-install:
	@found="$$(which smithy 2>/dev/null || true)"; \
	if [ "$$found" != "$(BINDIR)/smithy" ]; then \
		echo "smithy was linked into $(BINDIR), but $(BINDIR) is not on PATH." >&2; \
		if [ -n "$$found" ]; then echo "Current PATH resolves smithy to $$found." >&2; fi; \
		echo "Add $(BINDIR) to PATH and rerun make install." >&2; \
		exit 1; \
	fi
	@found="$$(which symphony 2>/dev/null || true)"; \
	if [ "$$found" != "$(BINDIR)/symphony" ]; then \
		echo "symphony was linked into $(BINDIR), but $(BINDIR) is not on PATH." >&2; \
		if [ -n "$$found" ]; then echo "Current PATH resolves symphony to $$found." >&2; fi; \
		echo "Add $(BINDIR) to PATH and rerun make install." >&2; \
		exit 1; \
	fi
	@echo "verified $$(which smithy)"
	@echo "verified $$(which symphony)"

next-steps:
	@printf '%s\n' \
		'Smithy installed. Next:' \
		'  $$ smithy add-repo <slug> <repo-path>' \
		'  $$ smithy daemon start <slug>' \
		'' \
		"Acknowledge prompts on first daemon start if you haven't already."
