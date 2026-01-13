# BucketButler 🛡️🪣

**BucketButler** is a high-performance, secure media delivery gateway built with Python and Google Cloud Functions. It provides a controlled interface for streaming files from Google Cloud Storage (GCS) to web applications, adding an essential layer of security and access control between your private storage buckets and the public internet. Note that **API Gateway is only available in certain regions**, so the script allows you to specify a different region for the Gateway and the Function.

---

## 🌟 Features

-   **Secure Media Streaming**: Serves files directly from GCS without exposing your bucket to the public.
-   **Dynamic ACL Protection**: Uses a `bucketlist.acl` file located in your bucket root to dynamically manage which folders are accessible in real-time.
-   **Chunked Delivery**: Efficiently handles large files by streaming them in chunks (256KB), reducing memory overhead.
-   **Gateway Masking**: Automatically strips common gateway prefixes (like `media/`) for cleaner URLs.
-   **Efficient Caching**: Implements a global cache for ACL rules to minimize GCS lookups and latency.
-   **Health Monitoring**: Built-in `/health` endpoint for uptime checks and container orchestration.

---

## 🚀 Quick Start

### 1. Prerequisites
-   A Google Cloud Project with Billing enabled.
-   Google Cloud SDK (`gcloud`) installed and authenticated.
-   A GCS Bucket (e.g., `my-media-bucket`).

### 2. Configure Access Control
Create a file named `bucketlist.acl` and upload it to the **root** of your GCS bucket. List the folders you want to make public:
```text
# bucketlist.acl
public-assets
marketing/images
user-thumbnails
```

### 3. Setup Environment Variables
BucketButler is designed to be fully portable. The core logic in `main.py` uses a placeholder:
-   `BUCKET_NAME`: The name of your GCS bucket. Defaults to `BUCKET_NAME_PLACEHOLDER` in the code but **must** be provided via environment variables during deployment.
-   `ACL_FILE`: (Optional) The name of your ACL file. Defaults to `bucketlist.acl`.

The `deploy.bash` script handles injecting these variables into the Cloud Function automatically using the `--set-env-vars` flag.

### 4. One-Step Deployment 🚀
BucketButler includes a comprehensive deployment script that automates the entire GCP infrastructure setup, including API enablement, IAM service account configuration, Cloud Function deployment, and API Gateway setup.

Before running, update the variables in `deploy.bash` to match your environment:
- `PROJECT_ID`: Your GCP Project ID.
- `BUCKET_NAME`: The GCS bucket you want to serve from.
- `FUNCTION_REGION`: The region for your Cloud Function (e.g., `asia-southeast1`).
- `GATEWAY_REGION`: A supported region for API Gateway (e.g., `asia-northeast1`).

```bash
chmod +x deploy.bash
./deploy.bash
```

This script will:
- Enable all required Google Cloud APIs.
- Create and configure a dedicated Service Account.
- Deploy the Python Cloud Function (Gen 2) to your `$FUNCTION_REGION`.
- Configure the Google API Gateway in your `$GATEWAY_REGION`.
- Provide you with the final Gateway URL and perform a connectivity test.

> **CRITICAL**: Ensure your `bucketlist.acl` is uploaded to the root of your bucket (`gs://your-bucket/bucketlist.acl`) before testing, otherwise you will receive a `403 Access Denied` response.

---

## 🛠️ Manual Deployment (Optional)
If you prefer to deploy only the function manually:
```bash
gcloud functions deploy bucket-butler \
  --runtime python310 \
  --trigger-http \
  --allow-unauthenticated \
  --set-env-vars BUCKET_NAME=your-bucket-name
```

---

## 🛠️ Architecture

BucketButler acts as a "Butler" for your storage:
1.  **Request**: Client requests `https://your-function-url/public-assets/logo.png`.
2.  **Verify**: BucketButler checks the cached `bucketlist.acl`.
3.  **Fetch**: If `public-assets` is listed, it fetches the blob from GCS.
4.  **Stream**: The file is streamed back to the client with the correct `Content-Type`.

---

## 📖 API Usage

-   **Get Asset**: `GET /{path_to_file}`
    -   Example: `GET /media/images/banner.jpg` (strips `media/` automatically)
-   **Health Check**: `GET /health`
    -   Returns `OK` (200)

---

## 👨‍💻 Author

**Bopaiah Mekerira**
*Passionate about building scalable AI and Cloud infrastructure.*

🔗 **Connect on LinkedIn**: [linkedin.com/in/bopaiah/](https://www.linkedin.com/in/bopaiah/)

---

## 📄 License

This project is licensed under the [MIT License](LICENSE). Feel free to use, modify, and distribute it in your own projects!
