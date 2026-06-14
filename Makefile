BUILD_DIR=build
APPS=front-end quotes newsfeed
STATIC_BASE=front-end/api/static
STATIC_PATHS=css
STATIC_ARCHIVE=$(BUILD_DIR)/static.tgz
DOCKER_TARGETS=$(addsuffix .docker, $(APPS))
DOCKER_PUSH_TARGETS=$(addsuffix .push, $(APPS))
_DOCKER_PUSH_TARGETS=$(addprefix _, $(DOCKER_PUSH_TARGETS))
GCR_URL=us-central1-docker.pkg.dev

default: deploy_interview

static: $(STATIC_ARCHIVE)

_test: $(addprefix _, $(addsuffix .test, $(LIBS) $(APPS)))

test:
	dojo "make _test"

_%.test:
	cd $* && python3 -m pip install -r requirements.txt && python3 -m pytest

login-gcloud:
	echo "Logging into GCP using interviewee credentials."
	gcloud auth activate-service-account --key-file=infra/.interviewee-creds.json

clean:
	rm -rf $(BUILD_DIR) $(addsuffix /target, $(APPS)) $(addsuffix /target, $(LIBS))

$(STATIC_ARCHIVE): | $(BUILD_DIR)
	tar -c -C $(STATIC_BASE) -z -f $(STATIC_ARCHIVE) $(STATIC_PATHS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

%.docker:
	$(eval IMAGE_NAME = $(subst -,_,$*))
	cd ./$* && docker buildx build --load --platform linux/amd64 -t $(IMAGE_NAME) .

%.push:
	# gcloud auth activate-service-account --key-file infra/.interviewee-creds.json
	$$(gcloud auth configure-docker us-central1-docker.pkg.dev --quiet)
	$(eval IMAGE_NAME = $(subst -,_,$*))
	docker tag $(IMAGE_NAME) $(GCR_URL)/$$(cat .projectid.txt)/images/$(IMAGE_NAME)
	docker push $(GCR_URL)/$$(cat .projectid.txt)/images/$(IMAGE_NAME)

docker: $(DOCKER_TARGETS)

_push: $(_DOCKER_PUSH_TARGETS)
push: $(DOCKER_PUSH_TARGETS)

_%.infra:
	@if [ ! -f .projectid.txt ]; then >&2 echo "No .projectid.txt found, ask your interviewer for a GCP projectId that you can put into this file" && exit 127; fi
	@if [ ! -f infra/.interviewee-creds.json ]; then >&2 echo "No infra/.interviewee-creds.json found" && exit 127; fi

	echo "Project id is $$(cat .projectid.txt)"
	export TF_VAR_project="$$(cat .projectid.txt)" \
		&& cd infra/$* \
		&& rm -rf .terraform \
		&& terraform init -backend-config="bucket=$${TF_VAR_project}-infra-backend" \
		&& terraform apply -auto-approve

%.infra:
	dojo "make _$*.infra"

_%.deinfra:
	export TF_VAR_project="$$(cat .projectid.txt)" \
		&& cd infra/$* \
		&& rm -rf .terraform \
		&& terraform init -backend-config="bucket=$${TF_VAR_project}-infra-backend" \
		&& terraform destroy -auto-approve

%.deinfra:
	dojo "make _$*.deinfra"

_deploy_site:
	gcloud auth activate-service-account --key-file infra/.interviewee-creds.json
	mkdir -p build/static
	cd build/static && \
		tar xf ../static.tgz && \
		gsutil rsync -R . gs://$(shell cat .projectid.txt)-infra-static-pages/

deploy_site:
	dojo "make _deploy_site"

news.infra:

deploy_interview:
	$(MAKE) static
	$(MAKE) base.infra
	$(MAKE) docker # builds all images
	$(MAKE) push
	$(MAKE) news.infra
	$(MAKE) deploy_site

destroy_interview:
	$(MAKE) news.deinfra
	$(MAKE) base.deinfra
