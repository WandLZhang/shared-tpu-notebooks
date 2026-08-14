# shared-tpu-notebooks
#
# PROJECT is required. Everything else has a working default.
#
#   make preflight   PROJECT=my-project      # read-only, costs nothing
#   make cluster     PROJECT=my-project      # ~12 min
#   make hub         PROJECT=my-project
#   make demo        PROJECT=my-project      # cluster + hub + one real TPU job
#   make scale       PROJECT=my-project      # 100 students through 32 chips
#   make teardown    PROJECT=my-project

PROJECT ?=
REGION  ?= us-west4
CLUSTER ?= tpu-notebooks
NS      ?= class-sec-a
export PROJECT REGION CLUSTER

.PHONY: check preflight cluster hub demo smoke scale report teardown venv

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

demo: cluster hub smoke
	@echo
	@echo "Reach the hub:  kubectl -n $(NS) port-forward service/proxy-public 8899:http"
	@echo "Then open http://localhost:8899 and log in with any username."

venv:
	python3 -m venv .venv && ./.venv/bin/pip install --quiet --upgrade pip

scale: check venv
	./.venv/bin/python scripts/04_scale_test.py --students 100 --chips 32
	./.venv/bin/python scripts/05_report.py

report: venv
	./.venv/bin/python scripts/05_report.py

teardown: check
	bash scripts/99_teardown.sh
