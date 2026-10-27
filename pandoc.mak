# Make rules to generate PDF and HTML from Markdown, see README.md
# Optional, set before or after including:
#   GFM2PDF_ENGINE  latex (default) or typst, can be set per target, e.g. `manual.pdf: GFM2PDF_ENGINE = typst`
# Optional, set before including:
#   GFM2PDF_THEME             theme folder (cover, fonts, ...), its files are dependencies of the documents,
#                             e.g. `GFM2PDF_THEME ?= ../brand/pdf_theme`
#   GFM2PDF_VERSION_REQUIRED  version of the toolchain required by the project, e.g. `~> 1.0`
# Defines GFM2PDF_VERSION: version of the toolchain.
# Variables of this file start with GFM2PDF_, so that they do not change the ones of the including Makefile.
GFM2PDF_MAK_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
GFM2PDF_GENERATOR := ruby $(GFM2PDF_MAK_DIR)lib/pandoc.rb
GFM2PDF_VERSION := $(shell cat $(GFM2PDF_MAK_DIR)VERSION)
ifneq ($(GFM2PDF_VERSION_REQUIRED),)
# Error message of the check, if any
GFM2PDF_VERSION_ERROR := $(shell $(GFM2PDF_GENERATOR) version '$(GFM2PDF_VERSION_REQUIRED)' 2>&1 >/dev/null)
ifneq ($(GFM2PDF_VERSION_ERROR),)
$(error $(GFM2PDF_VERSION_ERROR))
endif
endif
GFM2PDF_THEME ?=
GFM2PDF_DEPS := $(shell GFM2PDF_THEME='$(GFM2PDF_THEME)' $(GFM2PDF_GENERATOR) deps) $(GFM2PDF_MAK_DIR)pandoc.mak
GFM2PDF_ENGINE ?= latex

define markdown_to_pdf
$(2): $(1) $$(GFM2PDF_DEPS)
	GFM2PDF_ENGINE=$$(GFM2PDF_ENGINE) GFM2PDF_THEME=$$(GFM2PDF_THEME) $(GFM2PDF_GENERATOR) pdf $$< $$@
endef

define markdown_to_html
$(2): $(1) $$(GFM2PDF_DEPS)
	GFM2PDF_THEME=$$(GFM2PDF_THEME) $(GFM2PDF_GENERATOR) html $$< $$@
endef

$(eval $(call markdown_to_pdf,%.md,%.pdf))
