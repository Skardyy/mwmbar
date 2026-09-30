SRC := Sources

.PHONY: build run fmt fmt-check lint clean

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
