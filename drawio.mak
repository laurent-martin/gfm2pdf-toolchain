# Export the tabs of a draw.io file as images, see README.md
# Set before including:
#   DRAWIO_FILE     the .drawio file, e.g. images/diagrams.drawio
#   DRAWIO_FORMAT   image format (default: svg)
#   DRAWIO_OPTIONS  draw.io CLI options (default: --scale 2)
# Defines DRAWIO_IMAGES (one image per tab, next to the drawio file, named after the tab) and the target `diagrams`.
# For SVG, DRAWIO_IMAGES also has a PDF of each tab, used instead of the SVG in PDF documents.
DIR_DRAWIO_MAK := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
DRAWIO_TOOL := ruby $(DIR_DRAWIO_MAK)lib/drawio.rb
DRAWIO_FORMAT ?= svg
DRAWIO_OPTIONS ?= --scale 2
DRAWIO_IMAGES := $(shell $(DRAWIO_TOOL) list $(DRAWIO_FILE) $(DRAWIO_FORMAT))
ifeq ($(DRAWIO_FORMAT),svg)
DRAWIO_IMAGES += $(DRAWIO_IMAGES:.svg=.pdf)
endif

.PHONY: diagrams
diagrams: $(DRAWIO_IMAGES)

# An image is exported again only when older than the drawio file
$(DRAWIO_IMAGES): $(DRAWIO_FILE)
	$(DRAWIO_TOOL) export $< $@ $(DRAWIO_OPTIONS)
