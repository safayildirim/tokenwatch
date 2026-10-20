# These targets are short names for the scripts in scripts/, which hold the real build and install logic.
# Running "make" with no target prints this list.

.DEFAULT_GOAL := help
.PHONY: help build universal install test clean uninstall-launchagent launchagent

help:
	@echo "make install     Build the app, copy it to /Applications (or ~/Applications) and start it."
	@echo "make build       Build build/Tokenwatch.app without installing it."
	@echo "make universal   Build a universal (Apple silicon + Intel) app without installing it."
	@echo "make launchagent Install a LaunchAgent that starts the app at login and restarts it after a crash."
	@echo "make test        Run the test suite."
	@echo "make clean       Delete the build output."

build:
	scripts/build-app.sh

universal:
	scripts/build-app.sh --universal

# Installing always rebuilds first, so the installed app can never be older than the source.
install: build
	scripts/install.sh

launchagent:
	scripts/install-launchagent.sh

uninstall-launchagent:
	scripts/install-launchagent.sh --remove

test:
	swift test

clean:
	rm -rf build .build
