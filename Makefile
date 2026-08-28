# shared-tpu-notebooks
#
# PROJECT is required. Everything else has a working default.
#
#   make preflight   PROJECT=my-project      # read-only, costs nothing
#   make cluster     PROJECT=my-project      # ~12 min
#   make hub         PROJECT=my-project
#   make demo        PROJECT=my-project      # cluster + hub + one real TPU job
#   make iap         PROJECT=my-project      # HTTPS + Google sign-in, once
#   make warm-on     PROJECT=my-project      # hold WARM chips ready (default 1)
#   make warm-off    PROJECT=my-project
#   make scale       PROJECT=my-project      # 100 students through 32 chips
#   make teardown    PROJECT=my-project

PROJECT ?=
REGION  ?= us-west4
CLUSTER ?= tpu-notebooks
NS      ?= cmu-idl
WARM    ?= 1

# Course Scale and Configuration
STUDENTS      ?= 40
POOL_CHIPS    ?= 32
DOMAIN        ?= # e.g. jupyter.cs.cmu.edu
STUDENT_GROUP ?= # e.g. group:idl-11785-students@cmu.edu
TEST_ACCOUNTS ?= # e.g. user:test1@cmu.edu user:ta1@cmu.edu

export PROJECT REGION CLUSTER STUDENTS POOL_CHIPS DOMAIN STUDENT_GROUP TEST_ACCOUNTS

.PHONY: check preflight cluster hub iap warm-on warm-off demo smoke scale report teardown venv

check:
ifndef PROJECT
	$(error PROJECT is not set. Try: make $(MAKECMDGOALS) PROJECT=my-gcp-project)
endif

preflight: check
	bash scripts/00_preflight.sh

cluster: check
	bash scripts/02_create_cluster.sh

hub: check
	bash scripts/03_deploy_hub.sh

# One real job on one real chip. This is the proof the substrate works, and it is
# the thing to run before any scale test.
smoke: check
	sed -e 's/__STUDENT__/smoke-000/g' -e 's/__NAMESPACE__/$(NS)/g' -e 's/__QUEUE__/tpu/g' \
	  k8s/student-tpu-job.yaml | kubectl apply -f -
	kubectl -n $(NS) wait --for=condition=complete job/smoke-000 --timeout=900s
	kubectl -n $(NS) logs -l job-name=smoke-000 --tail=-1
	kubectl -n $(NS) delete job smoke-000

# HTTPS + Google sign-in via Identity-Aware Proxy. Run once per cluster. Replaces
# port-forwarding, which binds to a single proxy pod and dies when that pod moves.
iap: check
	bash scripts/08_setup_iap.sh

# Hold warm TPU nodes so the first job of the day skips the 2-4 min node build.
# Warm chips bill continuously, so turn them off when you are done.
warm-on: check
	bash scripts/07_warm_pool.sh on $(WARM)

warm-off: check
	bash scripts/07_warm_pool.sh off

demo: cluster hub smoke
	@echo
	@echo "Put the hub behind HTTPS and Google sign-in:  make iap PROJECT=$(PROJECT)"

venv:
	python3 -m venv .venv && ./.venv/bin/pip install --quiet --upgrade pip

scale: check venv
	./.venv/bin/python scripts/04_scale_test.py --students 100 --chips 32
	./.venv/bin/python scripts/05_report.py

report: venv
	./.venv/bin/python scripts/05_report.py

teardown: check
	bash scripts/99_teardown.sh
