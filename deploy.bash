#!/bin/bash

# ==============================================================================
# BUCKETBUTLER DEPLOYMENT SCRIPT
# Author: Bopaiah Mekerira
# LinkedIn: https://www.linkedin.com/in/bopaiah/
# ==============================================================================

# ==============================================================================
# CONFIGURATION
# ==============================================================================
export PROJECT_ID="${PROJECT_ID:-luvli-ai-tst}"
export BUCKET_NAME="${BUCKET_NAME:-test-sgpore}"

# Regional Settings
# Note: API Gateway is not available in asia-southeast1, so we use asia-northeast1 for the Gateway.
export FUNCTION_REGION="${FUNCTION_REGION:-asia-southeast1}"
export GATEWAY_REGION="${GATEWAY_REGION:-asia-northeast1}"

export SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-test-sgpore-runtime-sa}"
export FUNCTION_NAME="${FUNCTION_NAME:-test-sgpore-bridge}"
export API_ID="${API_ID:-test-sgpore-api}"
export API_CONFIG_ID="${API_CONFIG_ID:-test-sgpore-config-v1}"
export GATEWAY_ID="${GATEWAY_ID:-test-sgpore-gateway}"

# Fail fast on errors
set -e

# Ensure we are on the correct project
gcloud config set project $PROJECT_ID

echo "=============================================================================="
echo "Starting Deployment for Project: $PROJECT_ID"
echo "=============================================================================="

# ==============================================================================
# 1. ENABLE APIS
# ==============================================================================
echo "[1/7] Enabling required APIs..."
gcloud services enable \
    apigateway.googleapis.com \
    servicemanagement.googleapis.com \
    servicecontrol.googleapis.com \
    cloudfunctions.googleapis.com \
    run.googleapis.com \
    storage.googleapis.com \
    logging.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    --project=$PROJECT_ID

echo "Wait 10s for API enablement to reflect..."
sleep 10

# ==============================================================================
# 2. SETUP SERVICE ACCOUNT
# ==============================================================================
echo "[2/7] Setting up Service Account: $SERVICE_ACCOUNT_NAME..."

# Create SA if it doesn't exist
if ! gcloud iam service-accounts describe "${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --project="$PROJECT_ID" > /dev/null 2>&1; then
    gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
        --display-name="Luvli Gateway Runtime" \
        --project=$PROJECT_ID
    echo "Wait 10s for SA propagation..."
    sleep 10
else
    echo "Service account already exists."
fi

SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Grant Storage permissions (to read from bucket)
gcloud storage buckets add-iam-policy-binding gs://$BUCKET_NAME \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/storage.objectViewer"

# Grant Logging permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/logging.logWriter"

# Get Project Number for Cloud Build SA
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Grant SAs and Service Agents permission to use the runtime SA (required for Gen2)
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
BUILD_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
FUNC_AGENT="service-${PROJECT_NUMBER}@gcf-admin-robot.iam.gserviceaccount.com"

for MEMBER in "serviceAccount:$COMPUTE_SA" "serviceAccount:$BUILD_SA" "serviceAccount:$BUILD_AGENT" "serviceAccount:$FUNC_AGENT"; do
    gcloud iam service-accounts add-iam-policy-binding $SERVICE_ACCOUNT_EMAIL \
        --member="$MEMBER" \
        --role="roles/iam.serviceAccountUser" \
        --project=$PROJECT_ID
done

# Grant basic build permissions to the main build accounts
for SA in $COMPUTE_SA $BUILD_SA; do
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA}" \
        --role="roles/logging.logWriter"
    
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA}" \
        --role="roles/artifactregistry.admin"
    
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA}" \
        --role="roles/storage.objectViewer"
    
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:${SA}" \
        --role="roles/cloudbuild.builds.builder"
done

echo "Wait 10s for IAM permissions to propagate..."
sleep 10

# ==============================================================================
# 3. DEPLOY CLOUD FUNCTION
# ==============================================================================
echo "[3/7] Deploying Cloud Function: $FUNCTION_NAME..."
# Note: We use --no-allow-unauthenticated because the Gateway will authenticate via IAM
gcloud functions deploy $FUNCTION_NAME \
    --gen2 \
    --runtime=python311 \
    --region=$FUNCTION_REGION \
    --source=. \
    --entry-point=stream_file \
    --trigger-http \
    --no-allow-unauthenticated \
    --service-account=$SERVICE_ACCOUNT_EMAIL \
    --set-env-vars BUCKET_NAME=$BUCKET_NAME \
    --project=$PROJECT_ID

echo "Wait 10s for Cloud Function deployment to settle..."
sleep 10

# ==============================================================================
# 4. CONFIGURE ACCESS
# ==============================================================================
echo "[4/7] Granting Gateway permission to invoke Function..."
# The API Gateway, running as the service account, needs to be able to invoke the function.
# NOTE: API Gateway uses the account specified in backend-auth-service-account to CALL the backend.
# So we grant that same SA the invoker role on the function.

gcloud run services add-iam-policy-binding $FUNCTION_NAME \
    --region=$FUNCTION_REGION \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/run.invoker" \
    --project=$PROJECT_ID

echo "Wait 10s for invoker permissions to reflect..."
sleep 10

# ==============================================================================
# 5. PREPARE OPENAPI SPEC
# ==============================================================================
echo "[5/7] Preparing OpenAPI Spec..."

# Get the deployed function URL
FUNCTION_URL=$(gcloud functions describe $FUNCTION_NAME --gen2 --region=$FUNCTION_REGION --format="value(url)")
echo "Function URL: $FUNCTION_URL"

# Replace the placeholder in the YAML file with the actual URL
# We create a temporary file to avoid overwriting the source multiple times safely
sed "s|ADDRESS_PLACEHOLDER|$FUNCTION_URL|g" webstatic-api.yaml > webstatic-api-deployed.yaml

echo "Wait 10s for local spec preparation..."
sleep 10

# ==============================================================================
# 6. DEPLOY API CONFIG
# ==============================================================================
echo "[6/7] Creating API Config: $API_CONFIG_ID..."

# Create the API definition if it doesn't exist
if ! gcloud api-gateway apis describe "$API_ID" --project="$PROJECT_ID" > /dev/null 2>&1; then
    gcloud api-gateway apis create "$API_ID" --project="$PROJECT_ID"
fi

# Create a new config version (using a timestamp to ensure uniqueness if retrying)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
CONFIG_ID="${API_CONFIG_ID}-${TIMESTAMP}"

gcloud api-gateway api-configs create $CONFIG_ID \
    --api=$API_ID \
    --openapi-spec=webstatic-api-deployed.yaml \
    --backend-auth-service-account=$SERVICE_ACCOUNT_EMAIL \
    --project=$PROJECT_ID

echo "Wait 10s for API Config creation to settle..."
sleep 10

# ==============================================================================
# 7. DEPLOY/UPDATE GATEWAY
# ==============================================================================
echo "[7/7] Deploying API Gateway: $GATEWAY_ID..."

if gcloud api-gateway gateways describe $GATEWAY_ID --location=$GATEWAY_REGION --project=$PROJECT_ID > /dev/null 2>&1; then
    echo "Updating existing gateway..."
    gcloud api-gateway gateways update $GATEWAY_ID \
        --api=$API_ID \
        --api-config=$CONFIG_ID \
        --location=$GATEWAY_REGION \
        --project=$PROJECT_ID
else
    echo "Creating new gateway..."
    gcloud api-gateway gateways create $GATEWAY_ID \
        --api=$API_ID \
        --api-config=$CONFIG_ID \
        --location=$GATEWAY_REGION \
        --project=$PROJECT_ID
fi

echo "Wait 10s for Gateway deployment to stabilize..."
sleep 10

# ==============================================================================
# DONE
# ==============================================================================
GATEWAY_URL=$(gcloud api-gateway gateways describe $GATEWAY_ID --location=$GATEWAY_REGION --project=$PROJECT_ID --format="value(defaultHostname)")
echo "=============================================================================="

# Simple Verification
echo "Verifying access..."
TEST_FILE="docs/Lorem_ipsum.pdf"
echo "Testing file: $TEST_FILE"
echo "Gateway URL: https://$GATEWAY_URL/$TEST_FILE"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$GATEWAY_URL/$TEST_FILE")
if [ "$HTTP_CODE" == "403" ]; then
    echo "WARNING: Received 403 Forbidden. It may take a few minutes for permissions to propagate."
    echo "Please wait 1-2 minutes and try: curl -v https://$GATEWAY_URL/$TEST_FILE"
elif [ "$HTTP_CODE" == "200" ]; then
    echo "SUCCESS: Resource is accessible (HTTP 200)."
else
    echo "INFO: Received HTTP Code $HTTP_CODE for $TEST_FILE"
    echo "response body:"
    curl -s -L "https://$GATEWAY_URL/$TEST_FILE"
fi
echo "=============================================================================="