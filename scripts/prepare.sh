#!/usr/bin/env bash
# Author: Hung Tran
if [ $# -eq 0 ]
then
        echo "Missing options!"
        echo "(run $0 -h for help)"
        echo ""
        exit 0
fi
ENV=""

while getopts ":he:p:b:s:" OPTION; do
        case $OPTION in
                e)
                        ENV="$OPTARG"
                        ;;
                
                b)
                        BUCKET="$OPTARG"
                        ;;

                p)
                        PROJECT_ID="$OPTARG"
                        ;;
                
                s)      SEED_PROJECT="$OPTARG"
                        ;;

                h)
                        echo "Usage: $0 [ -s SEED_PROJECT ] [ -p PROJECT_ID ] [ -e ENVIRONMENT ]" 1>&2
                        echo ""
                        echo "   -s     GCP Shared Project"
                        echo "   -p     GCP Project ID"
                        echo "   -e     environment: dev/qa/prod..."
                        echo "   -b     Optional: GCS Bucket as Terraform Backend. Default value: <SEED_PROJECT>-tfstate"
                        echo "   -h     help (this output)"
                        exit 0
                        ;;

                *)
                    echo "Option $1 is not a valid option."
                    echo "Try './prepare.sh --help for more information."
                    shift
                    exit
                    ;;

        esac
done

if [ -z "$ENV"  ]   || [ -z "$PROJECT_ID" ] || [ -z "$SEED_PROJECT" ] ; then 
    echo "Error: ENV, PROJECT_ID and SEED_PROJECT cannot be empty"
    exit 1
fi

if [ -z "$BUCKET" ];
then
    BUCKET=$SEED_PROJECT-tfstate
    echo "No bucket defined. The bucket named $BUCKET will be selected as Terraform backend"
fi

# Color code
BLUE='\033[0;32m'

# On the shared project
gcloud config set project "$SEED_PROJECT"
TERRAFORM_SA=terraform
TERRAFORM_SA_EMAIL=${TERRAFORM_SA}@${SEED_PROJECT}.iam.gserviceaccount.com
gcloud services enable cloudresourcemanager.googleapis.com


yes '' | sed 2q # Add 2 blank lines
echo "Environment Info"
echo "Environment: ${ENV} "
echo "Project ID: ${PROJECT_ID} "
echo "Shared Project ID: ${SEED_PROJECT} "
echo "Terraform GCS Backend: ${BUCKET}"
echo "Terraform IAM Service Account: ${TERRAFORM_SA_EMAIL}"

# Create Terraform service account
if [[ $(gcloud iam service-accounts list --format="value(email)" --filter="email:${TERRAFORM_SA_EMAIL}" 2>&1) != "${TERRAFORM_SA_EMAIL}" ]]
then 
    echo "Create Terraform service account and grant the required permissions"
    gcloud iam service-accounts create terraform --description="Service Account for Terraform" --display-name="Terraform service account"
    gcloud iam service-accounts keys create ~/key.json --iam-account "${TERRAFORM_SA_EMAIL}"
fi

#Create GCS bucket as Terraform Backend
echo "Create/configure a GCS Bucket as Terraform Backend"
AVAIL=$(gsutil ls -p "$SEED_PROJECT" | grep -c "${BUCKET}" )
if [ "$AVAIL" -eq 0 ]
then 
    gsutil mb -p "$SEED_PROJECT" gs://"$BUCKET"
    gsutil versioning set on gs://"$BUCKET"
    gsutil acl ch -u ${TERRAFORM_SA_EMAIL}:W gs://"${BUCKET}"

else
    echo "Bucket ${BUCKET} already existed"
fi

# Generate the predefined Terraform backend configuration
ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$ROOT_DIR" || exit
cat <<EOT > ../"${ENV}"/terraform/tf-backend.tf
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "${ENV}"
  }  
}
EOT


# Switch to the environment project
gcloud config set project "$PROJECT_ID"
# Grant the role of owner to Terraform service account
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member serviceAccount:"${TERRAFORM_SA_EMAIL}" \
    --role roles/owner > /dev/null

yes '' | sed 2q # Add 2 blank lines
echo -e "${BLUE}Enable required APIs"
APIList="cloudresourcemanager.googleapis.com container.googleapis.com dns.googleapis.com sqladmin.googleapis.com redis.googleapis.com iam.googleapis.com servicenetworking.googleapis.com"
for api in $APIList
do
    if [[ $(gcloud services list --enabled --format="value(NAME)" --filter="NAME:${api}" 2>&1) != "${api}"  ]]
    then   
        echo "Enabling ${api}"
        gcloud services enable "$api"
    else 
        echo "$api is already enabled"
    fi
done
