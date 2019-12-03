#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2019 Joyent, Inc.
#

#
# Makefile: basic Makefile for template API service
#
# This Makefile is a template for new repos. It contains only repo-specific
# logic and uses included makefiles to supply common targets (javascriptlint,
# jsstyle, restdown, etc.), which are used by other repos as well. You may well
# need to rewrite most of this file, but you shouldn't need to touch the
# included makefiles.
#
# If you find yourself adding support for new targets that could be useful for
# other projects too, you should add these to the original versions of the
# included Makefiles (in eng.git) so that other teams can use them too.
#

#
# Tools
#
TAPE		:= ./node_modules/.bin/tape
NPM		:= npm
NGXSYMCHECK	= tools/ngx_symcheck

#
# Files
#
DOC_FILES	=
BASH_FILES	= bin/manta-mako-adm $(NGXSYMCHECK)
JS_FILES	:= $(shell find lib test bin -name '*.js')
JSL_CONF_NODE	= tools/jsl.node.conf
JSL_FILES_NODE	= $(JS_FILES)
SMF_MANIFESTS	= smf/manifests/nginx.xml

#
# Variables
#

# TODO: Use this to download or verify install of expected rust version
# NOTE: copied from what manta-buckets-mdapi uses
RUST_PREBUILT_VERSION = 1.33.0

NAME			= mako
NODE_PREBUILT_VERSION	= v8.16.1
NODE_PREBUILT_TAG	= zone64
# minimal-64 19.1.0
NODE_PREBUILT_IMAGE	= fbda7200-57e7-11e9-bb3a-8b0b548fcc37

#
# Stuff used for buildimage
#
# triton-origin-x86_64-19.2.0
BASE_IMAGE_UUID		= cbf116a0-43a5-447c-ad8c-8fa57787351c
BUILDIMAGE_NAME		= manta-storage
BUILDIMAGE_DESC		= Manta Storage
BUILDIMAGE_PKGSRC	= pcre-8.42 findutils-4.6.0nb2 gawk-4.2.1
AGENTS = amon config minnow registrar

ENGBLD_USE_BUILDIMAGE	= true
ENGBLD_REQUIRE :=	$(shell git submodule update --init deps/eng)
include ./deps/eng/tools/mk/Makefile.defs
TOP ?= $(error Unable to access eng.git submodule Makefiles.)

ifeq ($(shell uname -s),SunOS)
	include ./deps/eng/tools/mk/Makefile.node_prebuilt.defs
	include ./deps/eng/tools/mk/Makefile.agent_prebuilt.defs
	include ./deps/eng/tools/mk/Makefile.smf.defs
else
	NPM=npm
	NODE=node
	NPM_EXEC=$(shell which npm)
	NODE_EXEC=$(shell which node)
endif
include ./tools/mk/Makefile.nginx.defs

#
# MG Variables
#
ROOT            := $(shell pwd)
RELEASE_TARBALL := $(NAME)-pkg-$(STAMP).tar.gz
RELSTAGEDIR		:= /tmp/$(NAME)-$(STAMP)

#
# v8plus uses the CTF tools as part of its build, but they can safely be
# overridden here so that this works in dev zones without them.
# See marlin.git Makefile.
#
NPM_ENV          = MAKE_OVERRIDES="CTFCONVERT=/bin/true CTFMERGE=/bin/true"

#
# Repo-specific targets
#
.PHONY: all
all: $(NODE_EXEC) $(NGINX_EXEC) $(TAPE) $(REPO_DEPS) scripts build-rollup
	$(NPM) install
$(TAPE): | $(NPM_EXEC)
	$(NPM) install

CLEAN_FILES += $(TAPE) ./node_modules/ build

check-bash: $(NODE_EXEC)

.PHONY: test
test: $(TAPE)
	@for f in test/*.test.js; do	\
		echo "# $$f";	\
		$(TAPE) $$f || exit 1; \
	done

.PHONY: scripts
scripts: deps/manta-scripts/.git
	mkdir -p $(BUILD)/scripts
	cp deps/manta-scripts/*.sh $(BUILD)/scripts

.PHONY: check-nginx
check-nginx: $(NGINX_EXEC)
	$(NGXSYMCHECK) $(NGINX_EXEC)
prepush: check-nginx

.PHONY: release
release: all deps docs $(SMF_MANIFESTS) check-nginx
	@echo "Building $(RELEASE_TARBALL)"
	@mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/mako
	@mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/boot
	@mkdir -p $(RELSTAGEDIR)/site
	@touch $(RELSTAGEDIR)/site/.do-not-delete-me
	cp -r $(ROOT)/bin \
	    $(ROOT)/boot \
	    $(ROOT)/build \
	    $(ROOT)/build/nginx \
	    $(ROOT)/lib \
	    $(ROOT)/node_modules \
	    $(ROOT)/sapi_manifests \
	    $(ROOT)/smf \
	    $(RELSTAGEDIR)/root/opt/smartdc/mako/
	cp -r $(ROOT)/build/scripts $(RELSTAGEDIR)/root/opt/smartdc/mako/boot
	ln -s /opt/smartdc/mako/boot/setup.sh \
	    $(RELSTAGEDIR)/root/opt/smartdc/boot/setup.sh
	chmod 755 $(RELSTAGEDIR)/root/opt/smartdc/mako/boot/setup.sh
	rm $(RELSTAGEDIR)/root/opt/smartdc/mako/nginx/conf/*.default
	(cd $(RELSTAGEDIR) && $(TAR) -I pigz -cf $(ROOT)/$(RELEASE_TARBALL) root site)
	@rm -rf $(RELSTAGEDIR)

.PHONY: build-rollup
build-boray:
	(cd bin/mako_rollup && $(CARGO) build --release)
	find bin/mako_rollup -ls

.PHONY: publish
publish: release
	mkdir -p $(ENGBLD_BITS_DIR)/$(NAME)
	cp $(ROOT)/$(RELEASE_TARBALL) $(ENGBLD_BITS_DIR)/$(NAME)/$(RELEASE_TARBALL)

include ./deps/eng/tools/mk/Makefile.deps
ifeq ($(shell uname -s),SunOS)
	include ./deps/eng/tools/mk/Makefile.node_prebuilt.targ
	include ./deps/eng/tools/mk/Makefile.agent_prebuilt.targ
	include ./deps/eng/tools/mk/Makefile.smf.targ
endif
include ./tools/mk/Makefile.nginx.targ
include ./deps/eng/tools/mk/Makefile.targ
