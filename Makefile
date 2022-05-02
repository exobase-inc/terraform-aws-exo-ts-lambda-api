
#
# For testing.
#

.PHONY: init
plan:
	terraform init

.PHONY: plan
plan:
	terraform plan -var="context={\"service\":{\"name\":\"Demo 2\"}}"

.PHONY: apply
apply:
	terraform apply -var="context={\"service\":{\"name\":\"Demo 2\"}}"

#
# Publishing
#

.PHONY: login
login:
	exobase login

.PHONY: publish
publish:
	exobase publish