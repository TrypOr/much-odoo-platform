TF := terraform -chdir=terraform

.PHONY: up down smoke backup

up:
	$(TF) init -input=false
	$(TF) apply -auto-approve -target=terraform_data.cluster
	$(TF) apply -auto-approve

down:
	$(TF) destroy -auto-approve

smoke:
	./scripts/smoke.sh

backup:
	./scripts/backup.sh $(TENANT)
