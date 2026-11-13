TF := terraform -chdir=terraform

.PHONY: up down smoke backup restore-test grafana-password

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

restore-test:
	./scripts/restore-test.sh $(TENANT)

grafana-password:
	@$(TF) output -raw grafana_admin_password; echo
