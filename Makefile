SRC := Sources
REPO := Skardyy/mwmbar
FORMULA := Formula/mwmbar.rb

.PHONY: build run fmt fmt-check lint clean release

build:
	swift build

run:
	swift run

fmt:
	nix develop --command swift-format format --in-place --recursive $(SRC)

fmt-check:
	nix develop --command swift-format lint --recursive $(SRC)

lint:
	nix develop --command swiftlint lint --strict $(SRC)

clean:
	swift package clean

# build release binary and refresh the brew formula to point at the latest
# git tag. no git operations beyond reading tags are performed; tagging,
# committing, and pushing are left to the caller.
release:
	swift build -c release
	@tag=$$(git describe --tags --abbrev=0 2>/dev/null) || tag=""; \
	test -n "$$tag" || (echo "no git tag found" >&2; exit 1); \
	url="https://github.com/$(REPO)/archive/refs/tags/$$tag.tar.gz"; \
	echo "tag=$$tag"; \
	echo "fetching $$url"; \
	sha=$$(curl -fsSL "$$url" | shasum -a 256 | awk '{print $$1}'); \
	test -n "$$sha" || (echo "failed to compute sha256" >&2; exit 1); \
	echo "sha256=$$sha"; \
	sed -i.bak -E "s|^(  url ).*|\1\"$$url\"|; s|^(  sha256 ).*|\1\"$$sha\"|" $(FORMULA); \
	rm -f $(FORMULA).bak
	@echo "updated $(FORMULA); commit + push manually when ready."
