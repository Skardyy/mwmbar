SRC := Sources

.PHONY: build run fmt fmt-check lint clean

build:
	swift build

run:
	swift run

fmt:
	swift-format format --in-place --recursive $(SRC)

fmt-check:
	swift-format lint --recursive $(SRC)

lint:
	swiftlint lint --strict $(SRC)

clean:
	swift package clean
