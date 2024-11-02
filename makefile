.PHONY: all internal ffmpeg reset help install install_ffmpeg clean

# Default configuration
CONFIGURATION ?= release

# Validate CONFIGURATION
ifneq ($(CONFIGURATION),release)
ifneq ($(CONFIGURATION),debug)
$(error CONFIGURATION must be either 'release' or 'debug')
endif
endif

all: internal

internal:
	@echo "Building internal $(CONFIGURATION) version..."
	xcrun swift build --configuration $(CONFIGURATION) --arch arm64

ffmpeg:
	@echo "Building FFmpeg $(CONFIGURATION) version..."
	@if ! command -v ffmpeg &> /dev/null; then \
		echo "FFmpeg is not installed. Please install FFmpeg and try again."; \
		exit 1; \
	fi
	@if [ -f Package.internal.swift ] && [ -f Package.ffmpeg.swift ]; then \
		mv Package.swift Package.internal.swift; \
		mv Package.ffmpeg.swift Package.swift; \
		xcrun swift build -Xswiftc -DFFMPEG --configuration $(CONFIGURATION) --arch arm64; \
		$(MAKE) reset; \
	else \
		echo "Error: Package.internal.swift or Package.ffmpeg.swift not found."; \
		exit 1; \
	fi

reset:
	@if [ -f Package.internal.swift ] && [ -f Package.swift ]; then \
		mv Package.swift Package.ffmpeg.swift; \
		mv Package.internal.swift Package.swift; \
		echo "Package files reset."; \
	else \
		echo "Error: Package.internal.swift or Package.swift not found for reset."; \
		exit 1; \
	fi

install: internal
	@echo "Installing macSubtitleOCR..."
	install -m 755 .build/$(CONFIGURATION)/macSubtitleOCR /usr/local/bin

install_ffmpeg: ffmpeg
	@echo "Installing macSubtitleOCR with FFmpeg support..."
	install -m 755 .build/$(CONFIGURATION)/macSubtitleOCR /usr/local/bin

clean: reset
	@echo "Cleaning build artifacts..."
	rm -rf .build

help:
	@echo "Usage: make [internal|ffmpeg|install|install_ffmpeg|reset|clean] [CONFIGURATION=release|debug]"
	@echo "Targets:"
	@echo "  internal       - Build the internal version (default: release)"
	@echo "  ffmpeg         - Build the FFmpeg version (default: release)"
	@echo "  install        - Install the application"
	@echo "  install_ffmpeg - Install the application with FFmpeg support"
	@echo "  reset          - Reset the package files"
	@echo "  clean          - Clean the build artifacts"
	@echo "Variables:"
	@echo "  CONFIGURATION  - Build configuration (release or debug, default: release)"
